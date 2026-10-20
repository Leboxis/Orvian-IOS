#if DEBUG || ORVIAN_SPEECH_PROBE
import AVFoundation
import Observation
import Speech
import SwiftUI

@MainActor
@Observable
final class VideoSpeechProbe {
    static var isExposed: Bool {
        #if ORVIAN_SPEECH_PROBE
        return true
        #else
        return ProcessInfo.processInfo.environment["ORVIAN_SPEECH_PROBE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-OrvianSpeechProbe")
        #endif
    }

    private(set) var isRunning = false
    private(set) var needsDownload = false
    private(set) var status = "Prototype anglais uniquement, à 1×. Aucune validation kDrive acquise."
    private(set) var transcript = ""
    private(set) var buffers = 0
    private(set) var audioSeconds = 0.0
    private(set) var analyzedBuffers = 0
    private(set) var audioDiagnostic = ""
    private(set) var playbackDiagnostic = ""
    private(set) var mediaLag: Double?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var tap: PlayerSpeechAudioTap?
    @ObservationIgnored private var restoreAfterTapChange: (@MainActor () -> Void)?
    @ObservationIgnored private var wantsPlaybackValue = false
    var isCapturing: Bool { tap != nil }

    func start(player: AVPlayer, allowDownload: Bool = false,
               restorePlayback: @escaping @MainActor () -> Void = {},
               wantsPlayback: @escaping @MainActor () -> Bool = { false }) {
        guard !isRunning else { return }
        let previous = task
        previous?.cancel()
        generation &+= 1
        let token = generation
        let credential = TokenStore.credentialFingerprint()
        isRunning = true
        needsDownload = false
        transcript = ""
        buffers = 0
        audioSeconds = 0
        analyzedBuffers = 0
        audioDiagnostic = ""
        playbackDiagnostic = describePlayback(player, wantsPlayback: wantsPlayback())
        wantsPlaybackValue = wantsPlayback()
        restoreAfterTapChange = restorePlayback
        mediaLag = nil
        status = "Préparation du test…"
        task = Task { [weak self, weak player] in
            // Ne pas démarrer un deuxième analyseur avant la fin réelle du précédent.
            await previous?.value
            guard let self, let player, token == generation, !Task.isCancelled else { return }
            var installedTap: PlayerSpeechAudioTap?
            defer {
                installedTap?.detach()
                if token == generation {
                    tap = nil
                    monitorTask?.cancel()
                    monitorTask = nil
                    isRunning = false
                }
            }
            do {
                guard let item = player.currentItem, !player.isExternalPlaybackActive,
                      player.defaultRate == 1, player.rate == 0 || player.rate == 1 else {
                    status = "Test local uniquement : revenir à 1× et quitter AirPlay."
                    return
                }
                let asset = item.asset
                let isProtected = try await asset.load(.hasProtectedContent)
                let isComposable = try await asset.load(.isComposable)
                try checkSession(token: token, player: player, item: item, credential: credential)
                guard !isProtected, isComposable else { throw SpeechProbeError.source }
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                try checkSession(token: token, player: player, item: item, credential: credential)
                guard !tracks.isEmpty else { throw SpeechProbeError.noAudio }
                guard tracks.count == 1 else { throw SpeechProbeError.multipleTracks }
                guard SpeechTranscriber.isAvailable else { throw SpeechProbeError.unavailable }
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
                    throw SpeechProbeError.locale
                }
                try checkSession(token: token, player: player, item: item, credential: credential)
                let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
                let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                try checkSession(token: token, player: player, item: item, credential: credential)
                if let request = installation {
                    guard allowDownload else {
                        needsDownload = true
                        status = "Modèle anglais manquant. Le téléchargement nécessite du réseau."
                        return
                    }
                    status = "Téléchargement du modèle anglais…"
                    do { try await request.downloadAndInstall() }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw SpeechProbeError.model }
                }
                try checkSession(token: token, player: player, item: item, credential: credential)
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw SpeechProbeError.format
                }
                try Task.checkCancellation()
                guard token == generation, player.currentItem === item,
                      credential == TokenStore.credentialFingerprint() else { throw CancellationError() }
                let worker = SpeechProbeWorker(transcriber: transcriber, format: format)
                do {
                    status = "Préparation de SpeechAnalyzer…"
                    // Chauffer le modèle avant de recevoir du PCM dans la file bornée.
                    try await worker.prepare()
                    try checkSession(token: token, player: player, item: item, credential: credential)
                    let audioTap = try PlayerSpeechAudioTap(item: item, track: tracks[0])
                    installedTap = audioTap
                    tap = audioTap
                    // Changer le graphe audio peut interrompre la lecture. La reprise
                    // reste conditionnée par l'intention courante : une pause de
                    // l'utilisateur pendant la préparation doit primer.
                    let wasWanted = wantsPlayback()
                    try await Task.sleep(for: .milliseconds(250))
                    if wasWanted, wantsPlayback() { restoreAfterTapChange?() }
                    playbackDiagnostic = describePlayback(player, wantsPlayback: wasWanted)
                    status = "Tap installé ; en attente de PCM et de paroles anglaises…"
                    startMonitor(player: player, item: item, credential: credential, token: token)
                    try await worker.run(mailbox: audioTap.mailbox) { [weak self, weak player] event in
                        await self?.receive(event, player: player, token: token, credential: credential)
                    }
                    if token == generation {
                        status = buffers > 0 ? "Fin de l’audio. Vérifier le texte et les mesures avant décision GO."
                            : "Fin sans PCM : extraction non prouvée."
                    }
                } catch {
                    await worker.cancel()
                    throw error
                }
            } catch is CancellationError {
                if token == generation { transcript = ""; status = "Test interrompu." }
            } catch {
                if token == generation {
                    transcript = ""
                    status = (error as? SpeechProbeError)?.errorDescription ?? SpeechProbeError.analysis.localizedDescription
                }
            }
        }
    }

    func stop(reason: String = "Test arrêté.") {
        generation &+= 1
        // Le retrait du mix ne doit pas redémarrer une lecture que le lecteur
        // est en train de fermer ou que l'utilisateur a mise en pause.
        tap?.detach()
        tap = nil
        task?.cancel()
        monitorTask?.cancel()
        monitorTask = nil
        isRunning = false
        // Conserver le dernier texte reconnu : il documente ce que Speech a
        // réellement produit, même si le test s'arrête avant la fin du flux.
        mediaLag = nil
        status = reason
    }

    private func describePlayback(_ player: AVPlayer, wantsPlayback: Bool) -> String {
        let state: String
        switch player.timeControlStatus {
        case .playing: state = "lecture"
        case .paused: state = "pause"
        case .waitingToPlayAtSpecifiedRate: state = "attente (buffer)"
        @unknown default: state = "état inconnu"
        }
        return "intention=\(wantsPlayback ? "lecture" : "pause") état=\(state) vitesse=\(player.rate) externe=\(player.isExternalPlaybackActive ? "oui" : "non")"
    }

    private func checkSession(token: Int, player: AVPlayer, item: AVPlayerItem, credential: String?) throws {
        try Task.checkCancellation()
        guard token == generation, player.currentItem === item,
              credential == TokenStore.credentialFingerprint() else { throw CancellationError() }
        guard !player.isExternalPlaybackActive, player.defaultRate == 1,
              player.rate == 0 || player.rate == 1 else { throw SpeechProbeError.localPlayback }
    }

    private func receive(_ event: SpeechProbeEvent, player: AVPlayer?, token: Int, credential: String?) {
        guard token == generation, isRunning else { return }
        guard credential == TokenStore.credentialFingerprint() else {
            stop(reason: "Compte changé : test arrêté.")
            return
        }
        switch event {
        case let .audio(received, seconds, analyzed, diagnostic):
            buffers = received
            analyzedBuffers = analyzed
            audioSeconds = seconds
            audioDiagnostic = diagnostic
            if transcript.isEmpty { status = "Audio reçu (\(received) blocs) ; en attente de reconnaissance…" }
        case let .text(text, final, mediaEnd):
            transcript = text
            if let mediaEnd, let player {
                let lag = player.currentTime().seconds - mediaEnd
                mediaLag = lag.isFinite ? lag : nil
            } else {
                mediaLag = nil
            }
            status = final ? "Résultat définitif reçu — à vérifier sur la vidéo."
                : "Résultat provisoire reçu — à vérifier sur la vidéo."
        }
    }

    private func startMonitor(player: AVPlayer, item: AVPlayerItem, credential: String?, token: Int) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self, weak player, weak item] in
            var playingWithoutPCM = 0
            var idleSeconds = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let player, let item, token == generation else { return }
                guard credential == TokenStore.credentialFingerprint(), player.currentItem === item else {
                    stop(reason: "Source ou compte changé : test arrêté.")
                    return
                }
                guard !player.isExternalPlaybackActive else { stop(reason: "AirPlay : test local arrêté."); return }
                playbackDiagnostic = describePlayback(player, wantsPlayback: wantsPlaybackValue)
                if let tap {
                    audioDiagnostic = "Tap : \(tap.diagnostics()) · " + audioDiagnostic
                }
                if buffers == 0, player.timeControlStatus == .playing { playingWithoutPCM += 1 }
                if playingWithoutPCM >= 8 {
                    stop(reason: SpeechProbeError.noBuffers.localizedDescription)
                    return
                }
                // Le tap peut laisser le lecteur suspendu alors que l'utilisateur
                // veut lire : réaffirmer l'intention, jamais contredire une pause.
                if buffers == 0, wantsPlaybackValue, player.timeControlStatus != .playing {
                    restoreAfterTapChange?()
                }
                // Sans audio reçu et sans lecture active, le test ne peut pas aboutir :
                // le dire au lieu d'attendre indéfiniment.
                if buffers == 0, player.timeControlStatus != .playing {
                    idleSeconds += 1
                    if idleSeconds >= 10 {
                        stop(reason: "Aucune audio et lecture inactive : relancez la vidéo, puis le test.")
                        return
                    }
                } else {
                    idleSeconds = 0
                }
            }
        }
    }
}

/// Séparé du rendu vidéo ; absent de la Release normale, visible dans l'IPA de test dédié.
struct VideoSpeechProbePanel: View {
    let probe: VideoSpeechProbe
    let player: AVPlayer?
    /// Reprise conditionnée par l'intention de lecture du lecteur.
    let restorePlaybackRequested: @MainActor () -> Void
    let wantsPlaybackRequested: @MainActor () -> Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Test audio IA (développement)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(probe.status)
                Text("Audio reçu : \(probe.buffers) blocs · \(probe.audioSeconds, specifier: "%.1f") s · analysés \(probe.analyzedBuffers)")
                    .monospacedDigit()
                if !probe.audioDiagnostic.isEmpty {
                    Text(probe.audioDiagnostic).font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
                if !probe.playbackDiagnostic.isEmpty {
                    Text("Lecture : \(probe.playbackDiagnostic)").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
                if let lag = probe.mediaLag {
                    Text("Retard média : \(lag, specifier: "%.1f") s (pas une mesure de latence totale)")
                }
                if !probe.transcript.isEmpty { Text(probe.transcript).lineLimit(5) }
                Button(probe.isRunning ? "Arrêter le test" : probe.needsDownload ? "Télécharger le modèle anglais et tester" : "Tester l’audio anglais") {
                    if probe.isRunning { probe.stop() }
                    else if let player {
                        probe.start(
                            player: player,
                            allowDownload: probe.needsDownload,
                            restorePlayback: { restorePlaybackRequested() },
                            wantsPlayback: { wantsPlaybackRequested() }
                        )
                    }
                }
                .disabled(player == nil)
                .frame(minHeight: 44)
            }
        }
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: 340)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
    }
}
#endif
