import AVFoundation
import CoreML
import FluidAudio

/// Parakeet Ultra Core ML, FluidAudio v0.17.7 (revision pinned in project.yml).
/// https://github.com/FluidInference/FluidAudio/tree/v0.17.7
/// Only prepared captions use this model; live captions retain Apple's engine.
actor PreparedParakeetAnalyzer {
    static let shared = PreparedParakeetAnalyzer()
    private var isRunning = false

    func transcribe(url: URL, source: SubtitleSourceLanguage,
                    report: @escaping @Sendable (String, Double) async -> Void) async throws -> [PreparedSubtitle] {
        guard !isRunning else { throw PreparedSubtitleError.busy }
        isRunning = true
        defer { isRunning = false }
        try Task.checkCancellation()
        await report("Extraction de l’audio avec ses repères temporels…", 0)
        let audioURL = url.deletingLastPathComponent().appendingPathComponent("parakeet-audio.caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try await PreparedParakeetAudio.extract(asset: AVURLAsset(url: url), to: audioURL)
        try Task.checkCancellation()
        await report("Chargement de Parakeet Ultra… Premier téléchargement : environ 630 Mo.", 0.05)
        // The SDK defaults to debug logging. Never print recognized private audio.
        AppLogger.minimumLevel = .fault
        AppLogger.mirrorsToConsole = false
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let models = try await AsrModels.downloadAndLoad(configuration: configuration, version: .ultra)
        var cache = AsrModels.defaultCacheDirectory(for: .ultra)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cache.setResourceValues(values)
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
        do {
            try Task.checkCancellation()
            await report("Transcription avec Parakeet Ultra…", 0.1)
            var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
            let stream = await manager.transcriptionProgressStream
            let observer = Task {
                do {
                    for try await value in stream {
                        try Task.checkCancellation()
                        await report("Transcription avec Parakeet Ultra…", 0.1 + min(1, max(0, value)) * 0.9)
                    }
                } catch { /* The transcription call below owns error reporting. */ }
            }
            let result: ASRResult
            do {
                // The URL API switches to disk-backed windows above 30 seconds.
                // One concurrent window bounds model working memory on iPhone.
                result = try await manager.transcribe(audioURL, decoderState: &state,
                                                       language: Language(rawValue: source.rawValue))
            } catch {
                observer.cancel()
                await observer.value
                throw error
            }
            observer.cancel()
            await observer.value
            try Task.checkCancellation()
            let cues = try PreparedParakeetTiming.make(text: result.text, tokens: result.tokenTimings, source: source)
            await manager.cleanup()
            return cues
        } catch {
            await manager.cleanup()
            throw error
        }
    }
}

/// Keep the model's actual token times. Never estimate times from translated text.
enum PreparedParakeetTiming {
    static func make(text: String, tokens: [TokenTiming]?, source: SubtitleSourceLanguage) throws -> [PreparedSubtitle] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PreparedSubtitleError.noSpeech }
        guard let tokens, !tokens.isEmpty else { throw PreparedSubtitleError.timing }
        guard tokens.count <= 250_000 else { throw PreparedSubtitleError.tooLarge }
        let spans = tokens.map {
            PreparedSpeechSpan(start: $0.startTime, end: $0.endTime,
                               text: $0.token.replacingOccurrences(of: "▁", with: " "))
        }
        guard spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                == text.trimmingCharacters(in: .whitespacesAndNewlines) else { throw PreparedSubtitleError.timing }
        var previous = -Double.infinity
        for span in spans {
            guard span.start >= previous else { throw PreparedSubtitleError.timing }
            previous = span.start
        }
        return try PreparedSentenceBuilder.make(spans, source: source)
    }
}

/// Bounded PCM extraction. Insert silence for timeline gaps so model time zero
/// remains video time zero, including edited tracks with a nonzero first PTS.
enum PreparedParakeetAudio {
    static func extract(asset: AVAsset, to url: URL) async throws {
        let protected = try await asset.load(.hasProtectedContent)
        guard !protected else { throw PreparedSubtitleError.source }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw PreparedSubtitleError.noAudio }
        guard tracks.count == 1 else { throw PreparedSubtitleError.multipleTracks }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: format.settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PreparedSubtitleError.source }
        reader.add(output)
        defer { reader.cancelReading() }
        // AVAudioFile may retain buffered PCM until its Objective-C writer is
        // released. Drain its own pool before returning the URL to the model,
        // including on errors; keep the inner pool to bound per-buffer memory.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            guard reader.startReading() else { throw PreparedSubtitleError.source }
            var written: Int64 = 0
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            memset(silence.floatChannelData![0], 0, 16000 * MemoryLayout<Float>.size)
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0 else { return true }
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 16000,
                      count <= Int(Int32.max), let description = CMSampleBufferGetFormatDescription(sample),
                      AVAudioFormat(cmAudioFormatDescription: description) == format,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                    throw PreparedSubtitleError.timing
                }
                let position = Int64((seconds * 16000).rounded())
                // At most two samples of rounding noise; reject overlapping edits.
                guard position >= written - 2 else { throw PreparedSubtitleError.timing }
                while written < position {
                    try Task.checkCancellation()
                    let gap = min(Int64(16000), position - written)
                    silence.frameLength = AVAudioFrameCount(gap)
                    try file.write(from: silence)
                    written += gap
                }
                buffer.frameLength = AVAudioFrameCount(count)
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                    into: buffer.mutableAudioBufferList) == noErr else { throw PreparedSubtitleError.source }
                try file.write(from: buffer)
                written += Int64(count)
                return true
            }) { }
            try Task.checkCancellation()
            guard reader.status == .completed, written > 0 else { throw PreparedSubtitleError.source }
        }
    }
}
