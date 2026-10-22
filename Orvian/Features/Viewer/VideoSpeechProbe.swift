import AVFoundation
import Observation
import Speech
import SwiftUI
import Translation

@MainActor
@Observable
final class VideoSpeechProbe {
    static var isExposed: Bool {
        ProcessInfo.processInfo.environment["ORVIAN_SPEECH_PROBE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-OrvianSpeechProbe")
    }

    private(set) var isRunning = false
    private(set) var needsDownload = false
    private(set) var status = "Sous-titres automatiques vers le français."
    private(set) var transcript = ""
    private(set) var buffers = 0
    private(set) var audioSeconds = 0.0
    private(set) var analyzedBuffers = 0
    private(set) var speechResults = 0
    private(set) var speechTextResults = 0
    private(set) var audioDiagnostic = ""
    private(set) var playbackDiagnostic = ""
    private(set) var mediaLag: Double?
    /// Mode demandé par le bouton CC du lecteur.
    var mode: SubtitleMode = .off
    private(set) var sourceLanguage: SubtitleSourceLanguage = .english
    /// Transcription originale à afficher.
    private(set) var englishCue: SubtitleCue?
    /// Cue français à afficher (mode français).
    private(set) var frenchCue: SubtitleCue?
    private(set) var translationError: String?
    /// Configuration à passer à `.translationTask` : seule une session fournie
    /// par cette vue peut demander le téléchargement du modèle français.
    private(set) var translationConfiguration: TranslationSession.Configuration?
    private(set) var isPreparingTranslation = false
    /// Dernier cue à afficher, quel que soit le mode.
    var displayedCue: SubtitleCue? {
        switch mode {
        case .off: nil
        case .english: englishCue
        case .french: frenchCue
        }
    }
    @ObservationIgnored private var cues = SubtitleCueTimeline()
    @ObservationIgnored private var englishCues = SubtitleCueTimeline()
    @ObservationIgnored private var translator = SubtitleTranslator()
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var sentenceFlushTask: Task<Void, Never>?
    @ObservationIgnored private var sentences = SubtitleSentenceBuffer()
    @ObservationIgnored private var translationQueue = SubtitleTranslationQueue()
    @ObservationIgnored private var translationGeneration = 0
    private(set) var isTranslating = false
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    /// Tentatives de relance après une erreur transitoire ; plafonnée pour
    /// éviter une boucle si la source reste incompatible.
    @ObservationIgnored private var restartAttempts = 0
    private let maxRestartAttempts = 3
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var tap: PlayerSpeechAudioTap?
    @ObservationIgnored private var restoreAfterTapChange: (@MainActor () -> Void)?
    @ObservationIgnored private var wantsPlaybackValue = false
    /// Player fourni à `start`, conservé faiblement pour rafraîchir les cues et
    /// relancer la traduction sans le repasser en paramètre à chaque appel.
    @ObservationIgnored private weak var activePlayer: AVPlayer?
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
        speechResults = 0
        speechTextResults = 0
        audioDiagnostic = ""
        playbackDiagnostic = describePlayback(player, wantsPlayback: wantsPlayback())
        wantsPlaybackValue = wantsPlayback()
        restoreAfterTapChange = restorePlayback
        activePlayer = player
        if mode == .french, sourceLanguage != .french {
            configureTranslation()
            translationConfiguration?.invalidate()
        }
        mediaLag = nil
        status = "Préparation des sous-titres…"
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
                    status = "Sous-titres disponibles à 1×, hors AirPlay."
                    mode = .off
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
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: sourceLanguage.localeIdentifier)) else {
                    throw SpeechProbeError.locale
                }
                try checkSession(token: token, player: player, item: item, credential: credential)
                let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
                let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                try checkSession(token: token, player: player, item: item, credential: credential)
                if let request = installation {
                    guard allowDownload else {
                        needsDownload = true
                        status = "Modèle de transcription \(sourceLanguage.title.lowercased()) manquant. Le téléchargement nécessite du réseau."
                        return
                    }
                    status = "Téléchargement du modèle de transcription \(sourceLanguage.title.lowercased())…"
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
                    status = "En attente de paroles en \(sourceLanguage.title.lowercased())…"
                    startMonitor(player: player, item: item, credential: credential, token: token)
                    try await worker.run(mailbox: audioTap.mailbox) { [weak self, weak player] event in
                        await self?.receive(event, player: player, token: token, credential: credential)
                    }
                    if token == generation {
                        flushSentence()
                        status = buffers > 0
                            ? "Fin de l’audio : sous-titres arrêtés."
                            : "Aucun audio exploitable : sous-titres indisponibles."
                    }
                } catch {
                    await worker.cancel()
                    throw error
                }
            } catch is CancellationError {
                if token == generation { transcript = ""; status = "Sous-titres arrêtés." }
            } catch {
                if token == generation {
                    transcript = ""
                    let reason = (error as? SpeechProbeError)?.errorDescription
                        ?? SpeechProbeError.analysis.localizedDescription
                    // Incompatibilité de source : la vidéo reste lisible mais sans
                    // sous-titres. On coupe le mode pour ne pas boucler sur une
                    // erreur non récupérable.
                    let fatal: Bool
                    if case let probe as SpeechProbeError = error {
                        fatal = probe.isFatalForSubtitles
                    } else {
                        fatal = true
                    }
                    if fatal {
                        status = reason
                        mode = .off
                    } else {
                        // Discontinuité transitoire : `refresh` relancera la
                        // capture (plafonnée) sans couper les sous-titres.
                        status = reason + " Reconnexion…"
                    }
                }
            }
        }
    }

    /// Arrête la capture. `resetsAttempts` distingue un arrêt demandé par
    /// l'utilisateur (compteur neuf) d'un arrêt technique (seek, vitesse,
    /// changement de source) : seul le premier rend le budget de relances.
    func stop(reason: String = "Sous-titres arrêtés.", resetsAttempts: Bool = true) {
        generation &+= 1
        // Le retrait du mix ne doit pas redémarrer une lecture que le lecteur
        // est en train de fermer ou que l'utilisateur a mise en pause.
        tap?.detach()
        tap = nil
        task?.cancel()
        monitorTask?.cancel()
        monitorTask = nil
        clearTranslation()
        restartTask?.cancel()
        restartTask = nil
        if resetsAttempts { restartAttempts = 0 }
        isRunning = false
        englishCue = nil
        frenchCue = nil
        englishCues.clear()
        cues.clear()
        // Conserver le dernier texte reconnu : il documente ce que Speech a
        // réellement produit, même si les sous-titres s'arrêtent avant la fin.
        mediaLag = nil
        status = reason
    }

    /// Change de mode depuis le bouton CC. Revenir à `off` libère le tap.
    func setMode(_ newMode: SubtitleMode, player: AVPlayer?, start: () -> Void, stopTest: () -> Void) {
        guard newMode != mode else { return }
        mode = newMode
        // Choix utilisateur explicite : repartir avec un compteur de relances neuf.
        // Les reprises automatiques (seek/scrub/1×) continuent de l'accumuler.
        restartAttempts = 0
        translationError = nil
        clearTranslation()
        cues.clear()
        frenchCue = nil
        if newMode == .off {
            translationConfiguration = nil
            stopTest()
            return
        }
        configureTranslation()
        guard player != nil else { return }
        if !isRunning { start() }
    }

    /// Changer de langue invalide les transcriptions et traductions précédentes.
    func setSourceLanguage(_ language: SubtitleSourceLanguage) {
        guard sourceLanguage != language else { return }
        stop(reason: "Langue parlée : \(language.title).")
        sourceLanguage = language
        configureTranslation()
        // Le tick du lecteur relance la capture si les sous-titres sont actifs.
    }

    private func configureTranslation() {
        translationConfiguration = mode == .french && sourceLanguage != .french
            ? .init(source: Locale.Language(identifier: sourceLanguage.rawValue),
                    target: Locale.Language(identifier: "fr")) : nil
    }

    private func clearTranslation() {
        translationGeneration &+= 1
        translationTask?.cancel()
        translationTask = nil
        sentenceFlushTask?.cancel()
        sentenceFlushTask = nil
        sentences = SubtitleSentenceBuffer()
        translationQueue.clear()
        translator = SubtitleTranslator()
        isTranslating = false
        isPreparingTranslation = false
        translationError = nil
    }

    /// Prépare les modèles de traduction (téléchargement nécessite le
    /// consentement système, obtenu par `.translationTask`).
    func prepareTranslation(using session: TranslationSession) async {
        let token = translationGeneration
        isPreparingTranslation = true
        defer {
            if token == translationGeneration {
                isPreparingTranslation = false
                startTranslationIfNeeded()
            }
        }
        do {
            try await session.prepareTranslation()
            guard token == translationGeneration, mode == .french else { return }
            translationError = nil
        } catch is CancellationError {
            return
        } catch {
            guard token == translationGeneration else { return }
            translationError = SubtitleTranslationError.notInstalled.localizedDescription
        }
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
            stop(reason: "Compte changé : sous-titres arrêtés.", resetsAttempts: false)
            return
        }
        switch event {
        case let .audio(received, seconds, analyzed, diagnostic):
            buffers = received
            analyzedBuffers = analyzed
            audioSeconds = seconds
            audioDiagnostic = diagnostic
            // Une capture réelle annule le compteur de relances transitoires.
            restartAttempts = 0
            if transcript.isEmpty { status = "Audio reçu (\(received) blocs) ; en attente de reconnaissance…" }
        case let .text(text, final, mediaEnd, results, withText):
            speechResults = results
            speechTextResults = withText
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { transcript = text }
            if let mediaEnd, let player {
                let lag = player.currentTime().seconds - mediaEnd
                mediaLag = lag.isFinite ? lag : nil
            } else {
                mediaLag = nil
            }
            if !cleaned.isEmpty, let start = mediaEnd.map({ max(0, $0 - 3) }) {
                publishTranscript(text: cleaned, start: start, isFinal: final)
            }
            // « analysés » progresse sans texte : le problème est en aval de la conversion.
            status = withText > 0
                ? (final ? "Résultat définitif reçu — à vérifier sur la vidéo."
                         : "Résultat provisoire reçu — à vérifier sur la vidéo.")
                : "Speech produit des résultats sans texte (\(results)) ; audio peut-être vide ou non vocal."
        }
    }

    /// Met à jour la transcription et, si nécessaire, demande sa traduction.
    func publishTranscript(text: String, start: Double, isFinal: Bool) {
        let cue = SubtitleCue(start: start, end: start + 3, text: text,
                              isFinal: isFinal, isTranslated: false)
        englishCues.upsert(cue)
        guard mode == .french else { return }
        // Ne traduire que du texte stabilisé : retraduire chaque provisoire
        // ferait osciller l'affichage et saturerait le traducteur.
        guard isFinal else { return }
        if sourceLanguage == .french {
            publishFrench(text: cue.text, cue: cue)
            return
        }
        if let sentence = sentences.append(cue) { requestTranslation(for: sentence) }
        // Final sans ponctuation : attendre brièvement une suite, puis traduire
        // même si Speech ne produit plus rien (silence ou fin de vidéo).
        sentenceFlushTask?.cancel()
        let token = translationGeneration
        sentenceFlushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            guard let self, token == translationGeneration else { return }
            flushSentence()
        }
    }

    /// Rafraîchit le cue affiché selon la position de lecture.
    ///
    /// Appelé par le lecteur à chaque tick, même quand ses contrôles sont
    /// masqués. On ne publie que si le cue change : réassigner la même valeur
    /// quatre fois par seconde reconstruirait le lecteur pour rien.
    func refresh(player: AVPlayer) {
        guard mode != .off else {
            if englishCue != nil { englishCue = nil }
            if frenchCue != nil { frenchCue = nil }
            return
        }
        let time = player.currentTime().seconds
        let newEnglish = englishCues.cue(at: time)
        if newEnglish != englishCue { englishCue = newEnglish }
        // Les deux langues ont des timelines distinctes : un nouveau résultat
        // Speech ne doit jamais écraser le français déjà affiché.
        let newFrench = mode == .french ? cues.cue(at: time) : nil
        if newFrench != frenchCue { frenchCue = newFrench }
        scheduleRestartIfIdle(player: player)
    }

    /// Relance la capture après un seek, un scrub ou un retour à 1×.
    ///
    /// Ces gestes interrompent la session (l'analyseur refuse des horodatages
    /// qui reculent) ; sans relance, les sous-titres resteraient muets après un
    /// simple déplacement dans la vidéo.
    private func scheduleRestartIfIdle(player: AVPlayer) {
        guard !isRunning, restartTask == nil, mode != .off,
              player.timeControlStatus != .paused,
              player.defaultRate == 1, !player.isExternalPlaybackActive,
              !isPreparingTranslation else { return }
        // Récupération bornée : si la capture échoue de façon répétée (ex.
        // discontinuité persistante), on coupe proprement pour ne pas boucler.
        guard restartAttempts < maxRestartAttempts else {
            mode = .off
            status = "Sous-titres indisponibles après plusieurs tentatives."
            return
        }
        restartAttempts += 1
        restartTask = Task { [weak self, weak player] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, let player, !Task.isCancelled else { return }
            restartTask = nil
            guard mode != .off, !isRunning, player.defaultRate == 1,
                  !player.isExternalPlaybackActive else { return }
            start(player: player,
                  allowDownload: true,
                  restorePlayback: { self.restoreAfterTapChange?() },
                  wantsPlayback: { self.wantsPlaybackValue })
        }
    }

    private func flushSentence() {
        if let sentence = sentences.flush() { requestTranslation(for: sentence) }
    }

    private func requestTranslation(for cue: SubtitleCue) {
        translationQueue.append(cue)
        startTranslationIfNeeded()
    }

    private func startTranslationIfNeeded() {
        guard mode == .french, !isPreparingTranslation, translationTask == nil,
              translationQueue.count > 0 else { return }
        let token = translationGeneration
        let source = sourceLanguage
        let translator = self.translator
        isTranslating = true
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == translationGeneration {
                    translationTask = nil
                    isTranslating = false
                }
            }
            // Une seule traduction active. Ajouter une phrase ne l'annule pas.
            while token == translationGeneration, mode == .french,
                  !Task.isCancelled, let cue = translationQueue.popFirst() {
                do {
                    let translated = try await translator.translate(cue.text, source: source)
                    guard !Task.isCancelled, token == translationGeneration,
                          mode == .french else { return }
                    translationError = nil
                    publishFrench(text: translated, cue: cue)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, token == translationGeneration else { return }
                    translationError = (error as? LocalizedError)?.errorDescription
                        ?? SubtitleTranslationError.failed.localizedDescription
                }
            }
        }
    }

    private func publishFrench(text: String, cue: SubtitleCue) {
        // L'instant d'arrivée garantit une durée de lecture même en cas de
        // retard. Les prochains fragments originaux restent sur leur timeline.
        let position = activePlayer?.currentTime().seconds ?? cue.start
        let now = position.isFinite ? position : cue.start
        cues.upsert(SubtitleCue(start: now, end: max(now, cue.end), text: text,
                                isFinal: true, isTranslated: sourceLanguage != .french))
        if let player = activePlayer { refresh(player: player) }
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
                    stop(reason: "Source ou compte changé : sous-titres arrêtés.", resetsAttempts: false)
                    return
                }
                guard !player.isExternalPlaybackActive else {
                    stop(reason: "AirPlay : sous-titres locaux interrompus.", resetsAttempts: false)
                    return
                }
                playbackDiagnostic = describePlayback(player, wantsPlayback: wantsPlaybackValue)
                if let tap {
                    audioDiagnostic = "Tap : \(tap.diagnostics()) · " + audioDiagnostic
                }
                if buffers == 0, player.timeControlStatus == .playing { playingWithoutPCM += 1 }
                if playingWithoutPCM >= 8 {
                    stop(reason: SpeechProbeError.noBuffers.localizedDescription,
                         resetsAttempts: false)
                    return
                }
                // Le tap peut laisser le lecteur suspendu alors que l'utilisateur
                // veut lire : réaffirmer l'intention, jamais contredire une pause.
                if buffers == 0, wantsPlaybackValue, player.timeControlStatus != .playing {
                    restoreAfterTapChange?()
                }
                // Sans audio reçu et sans lecture active, les sous-titres ne
                // peuvent pas aboutir : le dire plutôt qu'attendre indéfiniment.
                // le dire au lieu d'attendre indéfiniment.
                if buffers == 0, player.timeControlStatus != .playing {
                    idleSeconds += 1
                    if idleSeconds >= 10 {
                        stop(reason: "Aucun audio et lecture inactive : relancez la vidéo, puis les sous-titres.",
                             resetsAttempts: false)
                        return
                    }
                } else {
                    idleSeconds = 0
                }
            }
        }
    }
}

/// Diagnostic interne du prototype. Masqué en production : le lecteur expose
/// désormais le bouton CC et l'overlay de sous-titres.
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
                Text("Audio reçu : \(probe.buffers) blocs · \(probe.audioSeconds, specifier: "%.1f") s · analysés \(probe.analyzedBuffers) · résultats \(probe.speechResults) (\(probe.speechTextResults) avec texte)")
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
                Button(probe.isRunning ? "Arrêter le test" : probe.needsDownload ? "Télécharger le modèle et tester" : "Tester l’audio") {
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
