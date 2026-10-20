#if DEBUG
import AVFoundation
import Speech

/// Erreurs volontairement sans URL, jeton ou texte privé issu des erreurs système.
enum SpeechProbeError: Error, LocalizedError {
    case unavailable, locale, format, source, noAudio, multipleTracks, existingMix, tapCreation
    case discontinuity, backpressure, sourceAudio, noBuffers, model, analysis, localPlayback

    var errorDescription: String? {
        switch self {
        case .unavailable: "SpeechTranscriber indisponible sur cet appareil."
        case .locale: "Le modèle anglais n’est pas pris en charge."
        case .format: "Format PCM non pris en charge par ce prototype mono/stéréo."
        case .source: "Source non composable ou protégée : HLS/DRM hors de ce prototype."
        case .noAudio: "Cette vidéo n’a pas de piste audio."
        case .multipleTracks: "Plusieurs pistes audio : sélection à valider avant ce test."
        case .existingMix: "Un mix audio existe déjà ; le test ne le remplace pas."
        case .tapCreation: "Impossible d’installer le tap audio."
        case .discontinuity: "Discontinuité audio : arrêtez puis relancez le test."
        case .backpressure: "File audio saturée ou occupée : test arrêté, lecture préservée."
        case .sourceAudio: "Le tap n’a pas pu lire les échantillons source."
        case .noBuffers: "Aucun PCM après 8 secondes de lecture : extraction non prouvée."
        case .model: "Préparation du modèle anglais impossible. Réessayez avec du réseau."
        case .analysis: "Analyse Speech interrompue ; aucune preuve de faisabilité acquise."
        case .localPlayback: "Test local uniquement : revenir à 1× et quitter AirPlay."
        }
    }
}

enum SpeechProbeEvent: Sendable {
    case audio(buffers: Int, seconds: Double)
    case text(String, isFinal: Bool, mediaEnd: Double)
}

/// Possède le convertisseur hors MainActor ; aucun buffer publié n'est recyclé.
actor SpeechProbeWorker {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var timeline = SpeechProbeTimeline()
    private var buffers = 0
    private var sourceSeconds = 0.0
    private var isFinished = false

    init(transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.transcriber = transcriber
        target = format
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func prepare() async throws {
        try await analyzer.prepareToAnalyze(in: target)
        try Task.checkCancellation()
    }

    func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        await analyzer.cancelAndFinishNow()
    }

    func run(mailbox: SpeechProbeMailbox<SpeechProbePacket>,
             report: @escaping @Sendable (SpeechProbeEvent) async -> Void) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(8))
        do {
            try Task.checkCancellation()
            try await analyzer.start(inputSequence: stream)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.readResults(report: report) }
                group.addTask {
                    do {
                        try await self.pump(mailbox: mailbox, continuation: continuation, report: report)
                        continuation.finish()
                        try await self.finish()
                    } catch {
                        continuation.finish()
                        await self.cancel()
                        throw error
                    }
                }
                do {
                    while try await group.next() != nil { }
                } catch {
                    group.cancelAll()
                    continuation.finish()
                    await cancel()
                    throw error
                }
            }
        } catch {
            continuation.finish()
            await cancel()
            throw error
        }
    }

    private func finish() async throws {
        try Task.checkCancellation()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        isFinished = true
    }

    private func readResults(report: @escaping @Sendable (SpeechProbeEvent) async -> Void) async throws {
        for try await result in transcriber.results {
            try Task.checkCancellation()
            guard let origin = timeline.origin else { continue }
            // Diagnostic uniquement : dernier segment, pas un historique de transcription.
            await report(.text(String(result.text.characters.suffix(500)), isFinal: result.isFinal,
                               mediaEnd: origin + result.range.end.seconds))
        }
    }

    private func pump(mailbox: SpeechProbeMailbox<SpeechProbePacket>,
                      continuation: AsyncStream<AnalyzerInput>.Continuation,
                      report: @escaping @Sendable (SpeechProbeEvent) async -> Void) async throws {
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: mailbox.byteCapacity, alignment: 16)
        defer { scratch.deallocate() }
        var lastReport = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            if let failure = mailbox.failure {
                switch failure {
                case .contention, .overflow: throw SpeechProbeError.backpressure
                case .oversized, .format: throw SpeechProbeError.format
                case .sourceAudio: throw SpeechProbeError.sourceAudio
                }
            }
            guard let packet = mailbox.pop(into: UnsafeMutableRawBufferPointer(start: scratch, count: mailbox.byteCapacity)) else {
                if mailbox.isClosed { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            if packet.startsStream, buffers > 0 { throw SpeechProbeError.discontinuity }
            if packet.frames > 0 {
                guard timeline.accept(start: packet.timeRange.start.seconds, duration: packet.timeRange.duration.seconds) else {
                    throw SpeechProbeError.discontinuity
                }
                let pcm = try makePCM(packet: packet, bytes: scratch)
                try convert(pcm, ending: false, continuation: continuation)
                buffers += 1
                sourceSeconds += Double(packet.frames) / pcm.format.sampleRate
            }
            if buffers == 1 || lastReport.duration(to: .now) >= .milliseconds(250) || packet.endsStream {
                await report(.audio(buffers: buffers, seconds: sourceSeconds))
                lastReport = .now
            }
            if packet.endsStream {
                try convert(nil, ending: true, continuation: continuation)
                return
            }
        }
    }

    private func makePCM(packet: SpeechProbePacket, bytes: UnsafeMutableRawPointer) throws -> AVAudioPCMBuffer {
        var description = packet.format
        guard let format = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: packet.frames) else {
            throw SpeechProbeError.format
        }
        pcm.frameLength = packet.frames
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let expectedCount = packet.secondBytes > 0 ? 2 : 1
        guard destination.count == expectedCount,
              Int(destination[0].mDataByteSize) >= packet.firstBytes,
              let first = destination[0].mData else { throw SpeechProbeError.format }
        first.copyMemory(from: bytes, byteCount: packet.firstBytes)
        if expectedCount == 2 {
            guard Int(destination[1].mDataByteSize) >= packet.secondBytes,
                  let second = destination[1].mData else { throw SpeechProbeError.format }
            second.copyMemory(from: bytes.advanced(by: packet.firstBytes), byteCount: packet.secondBytes)
        }
        return pcm
    }

    private func convert(_ input: AVAudioPCMBuffer?, ending: Bool,
                         continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        if let input {
            if let converter {
                guard converter.inputFormat == input.format else { throw SpeechProbeError.discontinuity }
            } else {
                guard let created = AVAudioConverter(from: input.format, to: target) else { throw SpeechProbeError.format }
                // shortcut: prime sans pré-roll pour le prototype ; alignement à mesurer sur appareil avant MVP.
                created.primeMethod = .none
                converter = created
            }
        }
        guard let converter else { return }
        var supplied = false
        while true {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
                throw SpeechProbeError.format
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if !supplied, let input {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            guard error == nil, status != .error else { throw SpeechProbeError.format }
            if output.frameLength > 0 {
                let firstFrame = timeline.advance(frames: Int64(output.frameLength))
                let time = CMTime(value: firstFrame, timescale: CMTimeScale(target.sampleRate))
                // L'ownership du PCM sortant est transféré ; aucune réécriture après yield.
                switch continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time)) {
                case .enqueued: break
                case .dropped: throw SpeechProbeError.backpressure
                case .terminated: throw CancellationError()
                @unknown default: throw SpeechProbeError.analysis
                }
            }
            if status == .inputRanDry || status == .endOfStream { return }
            guard output.frameLength > 0 else { throw SpeechProbeError.format }
        }
    }
}
#endif
