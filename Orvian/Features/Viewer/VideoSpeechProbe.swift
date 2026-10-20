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
    private(set) var mediaLag: Double?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var tap: PlayerSpeechAudioTap?
    var isCapturing: Bool { tap != nil }

    func start(player: AVPlayer, allowDownload: Bool = false) {
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
        tap?.detach()
        tap = nil
        task?.cancel()
        monitorTask?.cancel()
        monitorTask = nil
        isRunning = false
        transcript = ""
        mediaLag = nil
        status = reason
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
        case let .audio(count, seconds):
            buffers = count
            audioSeconds = seconds
            if transcript.isEmpty { status = "PCM reçu ; en attente de reconnaissance…" }
        case let .text(text, final, mediaEnd):
            transcript = text
            let lag = (player?.currentTime().seconds ?? .nan) - mediaEnd
            mediaLag = lag.isFinite ? lag : nil
            status = final ? "Résultat définitif reçu — à vérifier sur la vidéo."
                : "Résultat provisoire reçu — à vérifier sur la vidéo."
        }
    }

    private func startMonitor(player: AVPlayer, item: AVPlayerItem, credential: String?, token: Int) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self, weak player, weak item] in
            var playingWithoutPCM = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let player, let item, token == generation else { return }
                guard credential == TokenStore.credentialFingerprint(), player.currentItem === item else {
                    stop(reason: "Source ou compte changé : test arrêté.")
                    return
                }
                guard !player.isExternalPlaybackActive else { stop(reason: "AirPlay : test local arrêté."); return }
                if buffers == 0, player.timeControlStatus == .playing { playingWithoutPCM += 1 }
                if playingWithoutPCM >= 8 {
                    stop(reason: SpeechProbeError.noBuffers.localizedDescription)
                    return
                }
            }
        }
    }
}

/// Séparé du rendu vidéo ; absent de la Release normale, visible dans l'IPA de test dédié.
struct VideoSpeechProbePanel: View {
    let probe: VideoSpeechProbe
    let player: AVPlayer?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Test audio IA (développement)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(probe.status)
                Text("PCM : \(probe.buffers) blocs · \(probe.audioSeconds, specifier: "%.1f") s")
                    .monospacedDigit()
                if let lag = probe.mediaLag {
                    Text("Retard média : \(lag, specifier: "%.1f") s (pas une mesure de latence totale)")
                }
                if !probe.transcript.isEmpty { Text(probe.transcript).lineLimit(5) }
                Button(probe.isRunning ? "Arrêter le test" : probe.needsDownload ? "Télécharger le modèle anglais et tester" : "Tester l’audio anglais") {
                    if probe.isRunning { probe.stop() }
                    else if let player { probe.start(player: player, allowDownload: probe.needsDownload) }
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
