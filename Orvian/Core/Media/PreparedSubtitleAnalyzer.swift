import AVFoundation
import Speech

/// Lecture de la piste entière, hors MainActor, avec mémoire PCM bornée.
/// Aucun tap AVPlayer, microphone, horloge de lecture ou résultat provisoire.
actor PreparedSubtitleAnalyzer {
    static let shared = PreparedSubtitleAnalyzer()
    private var isRunning = false

    func transcribe(url: URL, source: SubtitleSourceLanguage,
                    progress: @escaping @Sendable (Double) async -> Void) async throws -> [PreparedSubtitle] {
        guard !isRunning else { throw PreparedSubtitleError.busy }
        isRunning = true
        defer { isRunning = false }
        // Only explicit preparation uses the extra audio decoder. Playback/live
        // capture remain unchanged, and native containers keep the Apple reader.
        let usesAudioDecoder = ["mkv", "mpg", "mpeg", "ts", "mts", "m2ts", "vob", "webm"].contains(url.pathExtension.lowercased())
        let assetDuration = usesAudioDecoder
            ? try await decodedDuration(url: url)
            : try await AVURLAsset(url: url).load(.duration).seconds
        var spans = try await analyze(url: url, source: source, range: nil, usesAudioDecoder: usesAudioDecoder) { value in await progress(value * 0.8) }
        let windows = PreparedSpeechRefinement.windows(for: spans, duration: assetDuration)
        for (index, range) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                let reread = try await analyze(url: url, source: source, range: range, usesAudioDecoder: usesAudioDecoder, progress: { _ in })
                spans = PreparedSpeechRefinement.merge(original: spans, reread: reread)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed optional reread does not invalidate the full first
                // pass. Keep its original words and uncertainty flags.
            }
            await progress(0.8 + 0.2 * Double(index + 1) / Double(windows.count))
        }
        try Task.checkCancellation()
        await progress(1)
        return try PreparedSentenceBuilder.make(spans, source: source)
    }

    private func decodedDuration(url: URL) async throws -> Double {
        let cancellation = try PreparedAudioCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let decoder = try PreparedAudioDecoder(url: url, sampleRate: 16_000, channels: 1, cancellation: cancellation)
            let duration = decoder.duration
            await decoder.close()
            try Task.checkCancellation()
            return duration
        } onCancel: { cancellation.cancel() }
    }

    private func analyze(url: URL, source: SubtitleSourceLanguage, range: CMTimeRange?, usesAudioDecoder: Bool,
                         progress: @escaping @Sendable (Double) async -> Void) async throws -> [PreparedSpeechSpan] {
        let asset: AVURLAsset?
        let audioTrack: AVAssetTrack?
        if usesAudioDecoder {
            asset = nil
            audioTrack = nil
        } else {
            let nativeAsset = AVURLAsset(url: url)
            let protected = try await nativeAsset.load(.hasProtectedContent)
            guard !protected else { throw PreparedSubtitleError.source }
            let tracks = try await nativeAsset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw PreparedSubtitleError.noAudio }
            guard tracks.count == 1 else { throw PreparedSubtitleError.multipleTracks }
            asset = nativeAsset
            audioTrack = tracks[0]
        }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: source.localeIdentifier)) else {
            throw PreparedSubtitleError.unavailable
        }
        // Sans fastResults/volatileResults : attendre les hypothèses définitives
        // du modèle, avec le contexte de l'enregistrement et les temps des mots.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.alternativeTranscriptions], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw PreparedSubtitleError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let cancellation = usesAudioDecoder ? try PreparedAudioCancellation() : nil
        let decoder: PreparedAudioDecoder?
        let reader: AVAssetReader?
        let output: AVAssetReaderTrackOutput?
        let duration: Double
        if let cancellation {
            guard format.sampleRate.isFinite, (16_000...192_000).contains(format.sampleRate),
                  format.sampleRate.rounded() == format.sampleRate else { throw PreparedSubtitleError.source }
            let decoded = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let value = try PreparedAudioDecoder(url: url, sampleRate: Int(format.sampleRate),
                                                     channels: Int(format.channelCount), cancellation: cancellation)
                try Task.checkCancellation()
                return value
            } onCancel: { cancellation.cancel() }
            decoder = decoded
            duration = decoded.duration
            reader = nil
            output = nil
        } else if let asset, let audioTrack {
            duration = try await asset.load(.duration).seconds
            let nativeReader = try AVAssetReader(asset: asset)
            if let range { nativeReader.timeRange = range }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: format.streamDescription.pointee.mBitsPerChannel,
                AVLinearPCMIsFloatKey: format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64,
                AVLinearPCMIsNonInterleaved: !format.isInterleaved,
                AVLinearPCMIsBigEndianKey: false
            ]
            let nativeOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            nativeOutput.alwaysCopiesSampleData = false
            guard nativeReader.canAdd(nativeOutput) else { throw PreparedSubtitleError.source }
            nativeReader.add(nativeOutput)
            decoder = nil
            reader = nativeReader
            output = nativeOutput
        } else { throw PreparedSubtitleError.source }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(4))
        defer { continuation.finish(); reader?.cancelReading(); cancellation?.cancel() }
        let spans = try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputSequence: stream)
                return try await withThrowingTaskGroup(of: [PreparedSpeechSpan]?.self) { group in
                    group.addTask { try await self.collect(transcriber) }
                    group.addTask {
                        if let decoder {
                            try await self.pump(decoder: decoder, format: format, range: range,
                                                duration: duration, continuation: continuation, progress: progress)
                        } else if let reader, let output {
                            try await self.pump(reader: reader, output: output, format: format,
                                                duration: duration, continuation: continuation, progress: progress)
                        } else { throw PreparedSubtitleError.source }
                        continuation.finish()
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        return nil
                    }
                    var collected: [PreparedSpeechSpan] = []
                    do {
                        while let value = try await group.next() {
                            if let value { collected = value }
                        }
                    } catch {
                        group.cancelAll()
                        cancellation?.cancel()
                        continuation.finish()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                    return collected
                }
            } catch {
                continuation.finish()
                cancellation?.cancel()
                await analyzer.cancelAndFinishNow()
                if let decoder { await decoder.close() }
                throw error
            }
        } onCancel: {
            // Annuler CET analyseur, pas un éventuel traitement suivant.
            cancellation?.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        if let decoder { await decoder.close() }
        try Task.checkCancellation()
        return spans
    }

    private func collect(_ transcriber: SpeechTranscriber) async throws -> [PreparedSpeechSpan] {
        var spans: [PreparedSpeechSpan] = []
        var alternativeBudget = 1_000_000
        for try await result in transcriber.results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            var current: [PreparedSpeechSpan] = []
            var prefix = ""
            var needsCoarseRange = false
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                if let range = run.audioTimeRange {
                    current.append(PreparedSpeechSpan(start: range.start.seconds, end: range.end.seconds,
                                                      text: prefix + text, beginsResult: current.isEmpty,
                                                      confidence: PreparedSpeechRefinement.confidence(run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self].map { Double($0) })))
                    prefix = ""
                } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if current.isEmpty { prefix += text } else { current[current.count - 1].text += text }
                } else {
                    needsCoarseRange = true
                }
            }
            if needsCoarseRange || current.isEmpty {
                let text = String(result.text.characters)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current = [PreparedSpeechSpan(start: result.range.start.seconds, end: result.range.end.seconds,
                                                  text: text, beginsResult: true,
                                                  confidence: result.text.runs.compactMap {
                                                      PreparedSpeechRefinement.confidence($0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self].map { Double($0) })
                                                  }.min())]
                }
            }
            if !current.isEmpty, current.contains(where: { $0.confidence.map { $0 < PreparedSpeechRefinement.uncertaintyThreshold } == true }) {
                let primary = String(result.text.characters)
                let alternatives = result.alternatives.lazy.map { String($0.characters) }
                    .filter { $0 != primary && !$0.isEmpty && $0.utf16.count <= 2000 }.prefix(3)
                for alternative in alternatives where alternative.utf16.count <= alternativeBudget {
                    current[0].alternatives.append(alternative)
                    alternativeBudget -= alternative.utf16.count
                }
            }
            spans.append(contentsOf: current)
            guard spans.count <= 250_000 else { throw PreparedSubtitleError.tooLarge }
        }
        return spans
    }

    private func pump(decoder: PreparedAudioDecoder, format: AVAudioFormat, range: CMTimeRange?,
                      duration: Double, continuation: AsyncStream<AnalyzerInput>.Continuation,
                      progress: @escaping @Sendable (Double) async -> Void) async throws {
        if let range { try await decoder.seek(to: range.start.seconds) }
        var previousTime = -Double.infinity
        var lastProgress = ContinuousClock.now
        while let chunk = try await decoder.read() {
            try Task.checkCancellation()
            guard chunk.startTime >= previousTime else { throw PreparedSubtitleError.timing }
            previousTime = chunk.startTime
            if let range, chunk.startTime >= range.end.seconds { break }
            guard let input = try chunk.input(format: format, range: range) else { continue }
            try await enqueue(input, into: continuation)
            if lastProgress.duration(to: .now) >= .milliseconds(200) {
                if duration.isFinite, duration > 0 { await progress(min(0.99, chunk.startTime / duration)) }
                lastProgress = .now
            }
        }
        try Task.checkCancellation()
    }

    private func enqueue(_ input: AnalyzerInput, into continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(input) {
            case .enqueued: return
            case .dropped: try await Task.sleep(for: .milliseconds(20))
            case .terminated: throw CancellationError()
            @unknown default: throw PreparedSubtitleError.source
            }
        }
    }

    func pump(reader: AVAssetReader, output: AVAssetReaderTrackOutput, format: AVAudioFormat,
                      duration: Double, continuation: AsyncStream<AnalyzerInput>.Continuation,
                      progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard reader.startReading() else { throw PreparedSubtitleError.source }
        var previousTime = -Double.infinity
        var lastProgress = ContinuousClock.now
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let description = CMSampleBufferGetFormatDescription(sample) else { throw PreparedSubtitleError.source }
            let actualFormat = AVAudioFormat(cmAudioFormatDescription: description)
            guard actualFormat == format else { throw PreparedSubtitleError.source }
            guard time.seconds.isFinite, time.seconds >= 0, time.seconds >= previousTime,
                  frames <= Int(Int32.max),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw PreparedSubtitleError.timing
            }
            previousTime = time.seconds
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                               into: buffer.mutableAudioBufferList) == noErr else {
                throw PreparedSubtitleError.source
            }
            // Garder les PTS de la piste vidéo, y compris un éventuel décalage
            // initial. Ne jamais repartir artificiellement à zéro.
            let input = AnalyzerInput(buffer: buffer, bufferStartTime: time)
            try await enqueue(input, into: continuation)
            if lastProgress.duration(to: .now) >= .milliseconds(200) {
                if duration.isFinite, duration > 0 { await progress(min(0.99, time.seconds / duration)) }
                lastProgress = .now
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw PreparedSubtitleError.source }
    }
}
