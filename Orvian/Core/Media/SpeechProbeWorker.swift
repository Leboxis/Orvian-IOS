#if DEBUG || ORVIAN_SPEECH_PROBE
import AVFoundation
import Speech

/// Erreurs volontairement sans URL, jeton ou texte privé issu des erreurs système.
enum SpeechProbeError: Error, LocalizedError {
    case unavailable, locale, format, source, noAudio, multipleTracks, existingMix, tapCreation
    case streamRestart, timeJump, formatChange, backpressure, sourceAudio, noBuffers, model, analysis, localPlayback

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
        case .streamRestart: "Discontinuité D1 : nouveau début de flux après réception audio."
        case .timeJump: "Discontinuité D2 : saut dans les positions audio source."
        case .formatChange: "Discontinuité D3 : format PCM modifié en cours de test."
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
    case audio(received: Int, seconds: Double, analyzed: Int, diagnostic: String)
    case text(String, isFinal: Bool, mediaEnd: Double?, results: Int, withText: Int)
}

/// Possède le convertisseur hors MainActor ; aucun buffer publié n'est recyclé.
actor SpeechProbeWorker {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var timeline = SpeechProbeTimeline()
    private var buffers = 0
    private var receivedBuffers = 0
    private var sourceSeconds = 0.0
    private var resultCount = 0
    private var textCount = 0
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
        // 64 buffers ≈ 12 s d'audio : absorbe le démarrage du modèle sans
        // déborder. Une file plus courte arrêtait le test dès la première seconde.
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingOldest(64)
        )
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
        // Marquer terminé seulement après la finalisation : si elle échoue,
        // `cancel()` doit encore pouvoir clore l'analyseur au lieu de le laisser ouvert.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        isFinished = true
    }

    private func readResults(report: @escaping @Sendable (SpeechProbeEvent) async -> Void) async throws {
        for try await result in transcriber.results {
            try Task.checkCancellation()
            resultCount += 1
            let text = String(result.text.characters.suffix(500))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { textCount += 1 }
            let mediaEnd = timeline.hasCompleteTiming ? timeline.origin.map { $0 + result.range.end.seconds } : nil
            // Transcrire même sans horodatage source ; ne pas prétendre être synchronisé dans ce cas.
            await report(.text(text, isFinal: result.isFinal, mediaEnd: mediaEnd,
                               results: resultCount, withText: textCount))
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
                if mailbox.isClosed {
                    // Le tap a livré tout ce qu'il pouvait : clore proprement la
                    // session Speech pour laisser sortir les derniers résultats.
                    try await convert(nil, ending: true, continuation: continuation)
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            let rate = packet.format.mSampleRate
            let duration = Double(packet.frames) / rate
            if packet.frames > 0 {
                receivedBuffers += 1
                if duration.isFinite, duration > 0 { sourceSeconds += duration }
                if receivedBuffers == 1 { await reportAudio(packet: packet, report: report) }
            }
            if packet.startsStream, receivedBuffers > 1 {
                // Le tap peut redémarrer son flux (nouvelle session après
                // installation du mix). Les seeks explicites arrêtent déjà le
                // test : ré-ancrer ici évite de perdre l'audio restant.
                timeline.restart()
                await reportAudio(packet: packet, report: report)
            }
            if packet.frames > 0 {
                guard rate.isFinite, rate > 0 else { throw SpeechProbeError.format }
                // La durée du PCM vient des frames réellement reçues, pas d'une
                // plage média parfois incomplète ou invalide.
                let acceptance = timeline.accept(start: packet.timeRange.start.seconds, duration: duration)
                guard let acceptance else { throw SpeechProbeError.format }
                let pcm = try makePCM(packet: packet, bytes: scratch)
                try await convert(pcm, ending: false, continuation: continuation)
                buffers += 1
                if acceptance == .restart {
                    await reportAudio(packet: packet, report: report)
                    throw SpeechProbeError.timeJump
                }
            }
            if buffers == 1 || lastReport.duration(to: .now) >= .milliseconds(250) || packet.endsStream {
                await reportAudio(packet: packet, report: report)
                lastReport = .now
            }
            if packet.endsStream {
                try await convert(nil, ending: true, continuation: continuation)
                return
            }
        }
    }

    private func reportAudio(packet: SpeechProbePacket,
                             report: @escaping @Sendable (SpeechProbeEvent) async -> Void) async {
        let start = packet.timeRange.start
        let duration = packet.timeRange.duration
        let clock = timeline.hasCompleteTiming ? "temps source fiable" : "temps source incomplet ou ré-ancré, retard non mesurable"
        let details = "frames=\(packet.frames) Hz=\(packet.format.mSampleRate) t=\(start.value)/\(start.timescale) flags=\(start.flags.rawValue) durée=\(duration.value)/\(duration.timescale) début=\(packet.startsStream ? 1 : 0) réancrages=\(timeline.reanchorCount) · \(clock)"
        await report(.audio(received: receivedBuffers, seconds: sourceSeconds, analyzed: buffers, diagnostic: details))
    }

    /// La politique de la file est `.bufferingOldest` : un yield peut être
    /// refusé pendant que Speech rattrape son retard. Réessayer brièvement
    /// évite d'arrêter tout le test sur un simple pic de charge.
    private func yieldWithBackpressure(_ input: AnalyzerInput,
                                       to continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            switch continuation.yield(input) {
            case .enqueued: return
            case .dropped:
                if ContinuousClock.now >= deadline { throw SpeechProbeError.backpressure }
                try await Task.sleep(for: .milliseconds(10))
            case .terminated: throw CancellationError()
            @unknown default: throw SpeechProbeError.analysis
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
                         continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {
        if let input {
            if let converter {
                guard converter.inputFormat == input.format else { throw SpeechProbeError.formatChange }
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
                try await yieldWithBackpressure(
                    AnalyzerInput(buffer: output, bufferStartTime: time),
                    to: continuation
                )
            }
            if status == .inputRanDry || status == .endOfStream { return }
            guard output.frameLength > 0 else { throw SpeechProbeError.format }
        }
    }
}
#endif
