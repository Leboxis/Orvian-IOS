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
        let assetDuration = try await AVURLAsset(url: url).load(.duration).seconds
        var spans = try await analyze(url: url, source: source, range: nil) { value in await progress(value * 0.8) }
        let windows = PreparedSpeechRefinement.windows(for: spans, duration: assetDuration)
        for (index, range) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                let reread = try await analyze(url: url, source: source, range: range, progress: { _ in })
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

    private func analyze(url: URL, source: SubtitleSourceLanguage, range: CMTimeRange?,
                         progress: @escaping @Sendable (Double) async -> Void) async throws -> [PreparedSpeechSpan] {
        let asset = AVURLAsset(url: url)
        let protected = try await asset.load(.hasProtectedContent)
        guard !protected else { throw PreparedSubtitleError.source }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw PreparedSubtitleError.noAudio }
        guard tracks.count == 1 else { throw PreparedSubtitleError.multipleTracks }
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
        let duration = try await asset.load(.duration).seconds
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: format.streamDescription.pointee.mBitsPerChannel,
            AVLinearPCMIsFloatKey: format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PreparedSubtitleError.source }
        reader.add(output)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(4))
        defer { continuation.finish(); reader.cancelReading() }
        let spans = try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputSequence: stream)
                return try await withThrowingTaskGroup(of: [PreparedSpeechSpan]?.self) { group in
                    group.addTask { try await self.collect(transcriber) }
                    group.addTask {
                        try await self.pump(reader: reader, output: output, format: format,
                                            duration: duration, continuation: continuation, progress: progress)
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
                        continuation.finish()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                    return collected
                }
            } catch {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            // Annuler CET analyseur, pas un éventuel traitement suivant.
            Task { await analyzer.cancelAndFinishNow() }
        }
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
                                                  text: text, beginsResult: true)]
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
            retry: while true {
                try Task.checkCancellation()
                switch continuation.yield(input) {
                case .enqueued: break retry
                case .dropped: try await Task.sleep(for: .milliseconds(20))
                case .terminated: throw CancellationError()
                @unknown default: throw PreparedSubtitleError.source
                }
            }
            if lastProgress.duration(to: .now) >= .milliseconds(200) {
                if duration.isFinite, duration > 0 { await progress(min(0.99, time.seconds / duration)) }
                lastProgress = .now
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw PreparedSubtitleError.source }
    }
}
