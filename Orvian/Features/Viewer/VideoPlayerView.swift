import SwiftUI
import AVFoundation
import Observation
import UIKit

/// Horloge de transport du lecteur, observée par la seule barre de temps.
///
/// `@Observable` : l'observateur périodique d'AVPlayer écrit `currentTime`
/// quatre fois par seconde quand les contrôles sont visibles. Tant que ces
/// valeurs vivaient dans le `@State` de `VideoPlayerView`, chaque tick
/// reconstruisait le corps entier du lecteur — barre du haut, boutons, zone
/// vidéo et couche `AVPlayerLayer` compris. Ici, seules les vues qui *lisent*
/// ces propriétés (la barre de transport) se rafraîchissent.
///
/// `scrubValue` y est rangée pour la même raison : elle suit le doigt à
/// ~60 Hz pendant un glissement, et la garder dans le `@State` du lecteur
/// reconstruirait toute la page à chaque frame du geste.
///
/// Pas d'isolateur d'acteur : la closure de l'observateur est `@Sendable` aux
/// yeux du compilateur, et toutes les écritures se font en pratique sur le fil
/// principal (`queue: .main`), comme les méthodes de la vue. Ce type ne fait
/// que porter des valeurs de transport.
@Observable
private final class PlaybackClock {
    /// Position de lecture courante (secondes).
    var currentTime: Double = 0
    /// Durée de l'élément, connue dès que l'observateur périodique la voit.
    var duration: Double = 0
    /// Fin de la plage bufferisée (pour la zone grisée du scrubber).
    var bufferedEnd: Double = 0
    /// Position du doigt pendant un glissement de la barre de progression.
    var scrubValue: Double = 0
}

/// Lecteur vidéo personnalisé : les barres (titre + boutons en haut,
/// transport en bas) sont hors de la zone de lecture de la vidéo.
/// Haut : tag et favori à gauche — muet + fermer à droite.
/// Bas : play/pause, progression agrandie, vitesse de lecture et AirPlay.
struct VideoPlayerView: View {
    let file: DriveFile
    let driveId: Int
    /// Vrai quand la page est l'élément courant d'un pager : seule la page
    /// active charge et lit la vidéo. Toujours vrai quand le lecteur est
    /// présenté seul (visionneuse directe).
    let isActive: Bool
    /// Verrouille le pager parent pendant un geste commencé sur le chrome du
    /// lecteur, sans empêcher le scrubber ni les boutons de recevoir ce geste.
    let onControlsInteractionChanged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var poster: UIImage?

    // Transport
    /// Position de lecture, durée, avance du tampon et position du doigt vivent
    /// dans cette référence observée séparément.
    ///
    /// L'observateur périodique d'AVPlayer écrit la position **quatre fois par
    /// seconde** pendant toute la lecture (contrôles visibles). Quand ces trois
    /// valeurs vivaient dans le `@State` de cette vue, chaque tick réévaluait le
    /// corps entier du lecteur — barre du haut, boutons, zone vidéo et couche
    /// `AVPlayerLayer` compris — soit quatre reconstructions par seconde. Seule
    /// la barre de transport observe désormais l'horloge.
    @State private var clock = PlaybackClock()
    @State private var transport = VideoPlaybackTransport()
    private var isScrubbing: Bool { transport.isScrubbing }
    /// Une recherche AVPlayer est asynchrone : tant qu'elle n'est pas terminée,
    /// le curseur doit rester sur la position demandée, pas sur l'ancienne
    /// position remontée par l'observateur périodique.
    private var isSeeking: Bool { transport.isSeeking }
    @State private var playbackRate: Float = 1

    // Son
    @AppStorage("videoMuted") private var isMuted = false

    // Favori
    @State private var isFavorite: Bool
    @State private var isFavoriteMutationInProgress = false

    // Tags
    @State private var appliedCategoryIds: Set<Int>
    @State private var showTagSheet = false
    /// La lecture reprend à la fermeture de la feuille uniquement si elle
    /// était active à l'ouverture.
    @State private var resumePlaybackAfterTags = false

    @State private var errorMessage: String?
    /// Une préparation a définitivement échoué : l'écran de préparation
    /// propose alors une relance au lieu d'attendre indéfiniment.
    @State private var hasFailedSetup = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var itemStatusObserver: NSKeyValueObservation?
    /// Observation du buffering ; l'intention de lecture vit dans transport.
    @State private var timeControlStatusObserver: NSKeyValueObservation?
    /// Vrai pendant qu'AVPlayer attend des données (image figée ≠ pause) :
    /// l'intention de lecture est conservée et un indicateur s'affiche.
    @State private var isBuffering = false
    /// Watchdog anti-stall : un `.waiting` qui dépasse ~20 s (lien signé
    /// expiré en cours de lecture, réseau coupé) ne produit jamais `.failed`,
    /// il faut donc le détecter soi-même et relancer.
    @State private var stallWatchdogTask: Task<Void, Never>?
    /// Conservée pendant les retries, y compris après épuisement du quota.
    private var recoveryPosition: Double? { transport.recoveryPosition }
    /// Anti-débounce des seeks « live » pendant le drag : la vidéo suit le
    /// doigt via des seeks grossiers, au plus un toutes les 100 ms.
    /// Référence (pas de reconstruction de vue à chaque acceptation).
    @State private var liveSeekThrottle = LiveSeekThrottle()
    @State private var playbackRetryCount = 0
    @State private var retryResetPosition: Double = 0
    @State private var isDisappeared = false
    @State private var isExternalPlaybackActive = false
    @State private var videoAreaWidth: CGFloat = 0
    /// Vrai pendant la préparation de la vidéo (conditionne le bouton
    /// « Réessayer »).
    @State private var isLoadingVideo = false
    /// Génération du chargement courant : chaque `load()` l'incrémente, si
    /// bien qu'une charge relancée par `.task(id:)` (retour sur la page)
    /// préempte celle, annulée, encore en vol au lieu d'être avalée par un
    /// garde-fou anti-doublon.
    @State private var loadGeneration = 0

    // Masquage automatique des contrôles après 2.5 secondes
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    /// Bascule des contrôles en attente : le premier tap d'un double-tap ne
    /// doit pas les masquer, sinon le second les fait revenir — un
    /// clignotement de 0 à 300 ms à chaque saut de 10 s.
    @State private var pendingToggleTask: Task<Void, Never>?
    /// Hauteurs réellement rendues, réutilisées par les zones gestuelles
    /// transparentes lorsque le chrome est masqué.
    @State private var topControlsHeight: CGFloat = 44
    @State private var bottomControlsHeight: CGFloat = 48

    // Rebond visuel du double-tap : pastille « ±10 s » brève du côté tapé.
    @State private var skipFeedback: SkipDirection?
    @State private var skipFeedbackResetTask: Task<Void, Never>?

    // Désambiguïsation manuelle simple/double tap (fenêtre 300 ms).
    @State private var lastTapDate: Date?
    @State private var lastTapLocation: CGPoint = .zero
    @GestureState private var isTouchingControls = false

    private let service = KDriveService()

    init(
        file: DriveFile,
        driveId: Int,
        isActive: Bool = true,
        onControlsInteractionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.file = file
        self.driveId = driveId
        self.isActive = isActive
        self.onControlsInteractionChanged = onControlsInteractionChanged
        _isFavorite = State(initialValue: file.isFavorite ?? false)
        _appliedCategoryIds = State(initialValue: Set((file.categories ?? []).map(\.categoryId)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            videoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { videoAreaWidth = $0 }
                .overlay(alignment: .center) {
                    skipFeedbackOverlay
                }
                // Détection manuelle du double-tap : le simple tap reste
                // instantané (un `onTapGesture(count: 2)` en amont retarde
                // chaque simple tap de la fenêtre de désambiguïsation).
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    handleVideoTap(at: location)
                }
                .accessibilityAction(named: Text("Reculer de 10 secondes")) { skipTime(by: -10) }
                .accessibilityAction(named: Text("Avancer de 10 secondes")) { skipTime(by: 10) }

            hiddenControlGestureRegions

            VStack(spacing: 0) {
                topBar
                    .contentShape(Rectangle())
                    .simultaneousGesture(controlRegionGesture)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        topControlsHeight = $0
                    }
                Spacer()
                bottomBar
                    .contentShape(Rectangle())
                    .simultaneousGesture(controlRegionGesture)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        bottomControlsHeight = $0
                    }
            }
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)
            .accessibilityHidden(!showControls)
            .animation(Motion.animation(.easeInOut(duration: 0.25)), value: showControls)
        }
        .onAppear {
            isDisappeared = false
            showControls = true
            scheduleControlsAutoHide(delay: 2.5)
            // La session audio est retenue par `startPlayback` (et non ici) :
            // une page voisine du pager qui apparaît sans jouer ne doit pas
            // réserver la session.
        }
        .task(id: isActive) {
            // Dans un pager, les pages hors écran ne chargent jamais : seule
            // la page courante (re)prépare et lit sa vidéo.
            guard isActive else { return }
            isDisappeared = false
            await load()
        }
        .onChange(of: isActive) { _, active in
            if active {
                showControls = true
                scheduleControlsAutoHide(delay: 2.5)
                // `.task(id:)` est l'unique point de reprise de la page.
            } else {
                // Page quittée : la lecture s'arrête, le lecteur reste prêt.
                hideControlsTask?.cancel()
                pendingToggleTask?.cancel()
                pendingToggleTask = nil
                pausePlayback()
                cancelPendingSeek()
                _ = transport.endScrub()
                loadGeneration &+= 1
            }
        }
        .onDisappear {
            isDisappeared = true
            loadGeneration &+= 1
            hideControlsTask?.cancel()
            pendingToggleTask?.cancel()
            pendingToggleTask = nil
            onControlsInteractionChanged(false)
            teardown()
        }
        .onChange(of: isMuted) { _, muted in player?.isMuted = muted }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { pausePlayback() }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { showControls = true }
            scheduleControlsAutoHide()
        }
        .onChange(of: showControls) { _, _ in
            if let player { updateTimeObserver(for: player) }
        }
        .onChange(of: isTouchingControls) { _, isTouching in
            onControlsInteractionChanged(isTouching)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard !isDisappeared,
                  rawReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            // Également actif pendant une récupération, quand player est nil.
            pausePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard !isDisappeared,
                  rawType == AVAudioSession.InterruptionType.began.rawValue else { return }
            pausePlayback()
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(
            isPresented: $showTagSheet,
            onDismiss: {
                guard resumePlaybackAfterTags else { return }
                resumePlaybackAfterTags = false
                requestPlayback()
            }
        ) {
            TagsEditorSheet(
                driveId: driveId,
                file: file,
                initialAppliedIds: appliedCategoryIds,
                onChanged: { category, applied in
                    if applied {
                        appliedCategoryIds.insert(category.id)
                    } else {
                        appliedCategoryIds.remove(category.id)
                    }
                    FileGridMutationCenter.shared.publish(
                        .category(driveId: driveId, fileId: file.id, category: category, applied: applied)
                    )
                }
            )
        }
    }

    // MARK: - Gestion de l'affichage des contrôles

    /// Reconnaît le contact sur une barre avant que le pager atteigne son
    /// seuil horizontal. GestureState se réinitialise aussi sur annulation.
    private var controlRegionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouchingControls) { _, isTouching, _ in
                isTouching = true
            }
    }

    /// Quand les contrôles sont invisibles, ces bandes conservent exactement
    /// leurs zones réservées. Elles bloquent le swipe du pager et un tap y
    /// réaffiche le chrome, sans rendre les boutons invisibles actionnables.
    private var hiddenControlGestureRegions: some View {
        VStack(spacing: 0) {
            hiddenControlGestureRegion(height: topControlsHeight)
            Spacer()
            hiddenControlGestureRegion(height: bottomControlsHeight)
        }
        .allowsHitTesting(!showControls)
    }

    private func hiddenControlGestureRegion(height: CGFloat) -> some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .simultaneousGesture(controlRegionGesture)
            .onTapGesture {
                guard !showControls else { return }
                pendingToggleTask?.cancel()
                pendingToggleTask = nil
                toggleControls()
            }
    }

    private func scheduleControlsAutoHide(delay: Double = 2.5) {
        hideControlsTask?.cancel()
        guard !voiceOverEnabled else { return }
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if !isScrubbing, !isSeeking {
                withAnimation(Motion.animation(.easeInOut(duration: 0.25))) {
                    showControls = false
                }
            }
        }
    }

    private func toggleControls() {
        guard !voiceOverEnabled else { showControls = true; return }
        withAnimation(Motion.animation(.easeInOut(duration: 0.25))) {
            showControls.toggle()
        }
        if showControls {
            scheduleControlsAutoHide(delay: 2.5)
        } else {
            hideControlsTask?.cancel()
        }
    }

    // MARK: - Barre du haut (hors zone vidéo)

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                tagMenu
                favoriteButton
                Spacer()
            }
            MediaTitlePill(name: file.name)
            HStack(spacing: 8) {
                Spacer()
                muteButton
                closeButton
            }
        }
        .padding(.horizontal, 0)
        .padding(.top, -4)
        .padding(.bottom, 2)
    }

    // MARK: - Zone vidéo

    @ViewBuilder
    private var videoArea: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
                // Image figée pendant que le tampon se remplit : l'indicateur
                // distingue cette attente d'une vraie pause.
                if isBuffering {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                }
            } else if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
            }
            if isExternalPlaybackActive {
                VStack(spacing: 12) {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                    Text("Lecture en cours via AirPlay")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(24)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if player == nil {
                preparing
            }
        }
    }

    private var preparing: some View {
        VStack(spacing: 12) {
            if poster == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            }
            Text(hasFailedSetup ? "Lecture impossible pour le moment." : "Préparation de la lecture…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
            if hasFailedSetup, !isLoadingVideo {
                Button {
                    playbackRetryCount = 0
                    errorMessage = nil
                    Task { await load() }
                } label: {
                    Label("Réessayer", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(20)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Barre du bas (transport, hors zone vidéo)

    private var bottomBar: some View {
        HStack(spacing: 8) {
            playButton

            // Position, durée et plage tampon sont observées par cette seule
            // sous-vue (`TransportTimeView`) : l'observateur périodique
            // d'AVPlayer ne reconstruit donc plus le lecteur, ni la zone vidéo,
            // ni les barres du haut, quatre fois par seconde.
            TransportTimeView(
                clock: clock,
                isScrubbing: isScrubbing,
                isSeeking: isSeeking,
                timeFormatter: { timeText($0) },
                onDragStarted: beginScrub,
                onDragChanged: updateScrub(to:),
                onDragEnded: endScrub(to:),
                onDragCancelled: cancelScrub
            )

            speedMenu

            AirPlayButton()
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 0)
        .padding(.top, 2)
        .padding(.bottom, -4)
    }

    // MARK: - Scrubbing (barre personnalisée)

    /// Début du glissement : mémorise l'état, coupe le son de lecture et
    /// prépare la prévisualisation. La vidéo suivra le doigt via des seeks
    /// grossiers throttlés (`updateScrub`).
    private func beginScrub() {
        guard player != nil, isActive, !isDisappeared, !showTagSheet else { return }
        hideControlsTask?.cancel()
        cancelPendingSeek()
        transport.clearRecoveryPosition()
        clock.scrubValue = playerTime ?? clock.currentTime
        transport.beginScrub()
        // Le son cesse pendant le geste : le suivi visuel sous le doigt
        // remplace la lecture (comportement natif).
        player?.pause()
    }

    private func updateScrub(to seconds: Double) {
        guard isScrubbing else { return }
        clock.scrubValue = max(0, seconds)
        scheduleLiveScrubSeek(to: seconds)
    }

    /// Seek grossier throttlé : tolérance 1,5 s → AVPlayer saute au keyframe
    /// le plus proche et la couche vidéo principale suit le doigt sans
    /// attendre l'image exacte (le seek final précis intervient au relâchement).
    private func scheduleLiveScrubSeek(to seconds: Double) {
        guard let player else { return }
        let now = Date()
        guard liveSeekThrottle.shouldSeek(now: now) else { return }
        liveSeekThrottle.accept(now)
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Ne garde que la dernière intention : sans cette annulation, ~10 seeks/s
        // s'accumulent pendant le drag et le décodeur rejoue des keyframes dépassées.
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: target,
            toleranceBefore: CMTime(seconds: 1.5, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 1.5, preferredTimescale: 600)
        )
    }

    private func endScrub(to seconds: Double) {
        guard transport.endScrub() else { return }
        liveSeekThrottle.reset()
        // Seek final précis + reprise conditionnelle (déjà gérés par `seek`).
        seek(to: seconds, precise: true)
    }

    private func cancelScrub() {
        guard transport.endScrub() else { return }
        cancelPendingSeek()
        liveSeekThrottle.reset()
        clock.currentTime = playerTime ?? clock.currentTime
        clock.scrubValue = clock.currentTime
        resumePlaybackIfRequested()
        scheduleControlsAutoHide(delay: 2.5)
    }

    // MARK: - Boutons

    private var playButton: some View {
        Button {
            togglePlay()
        } label: {
            Image(systemName: transport.wantsPlayback ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
        }
        .disabled(player == nil)
        .accessibilityLabel(transport.wantsPlayback ? "Pause" : "Lecture")
    }

    private var favoriteButton: some View {
        MediaFavoriteButton(
            isFavorite: isFavorite,
            isDisabled: isFavoriteMutationInProgress
        ) {
            Task { await toggleFavorite() }
        }
    }

    private var muteButton: some View {
        Button {
            isMuted.toggle()
            player?.isMuted = isMuted
            scheduleControlsAutoHide(delay: 2.5)
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel(isMuted ? "Réactiver le son" : "Couper le son")
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
        }
        .accessibilityLabel("Fermer")
    }

    /// Titre formaté de la vitesse actuelle (ex: 1x, 1,5x, 2x).
    private var currentSpeedTitle: String {
        if let match = SpeedOption.allCases.first(where: { abs($0.rate - playbackRate) < 0.01 }) {
            return match.title
        }
        return "1x"
    }

    /// Vitesse de lecture : petite pastille en bas à droite avec menu interactif.
    private var speedMenu: some View {
        Menu {
            ForEach(SpeedOption.allCases) { option in
                Button {
                    setPlaybackRate(option.rate)
                } label: {
                    HStack {
                        Text(option.title)
                        Spacer()
                        if abs(option.rate - playbackRate) < 0.01 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(currentSpeedTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Vitesse de lecture")
    }

    /// Éditeur de tags : feuille partagée avec la fiche fichier (cartes de
    /// l'onglet Tag, couleurs visibles, tri par usage). Le Menu natif était
    /// écrasé par UIKit : pastilles de couleur perdues, liste peu maniable.
    private var tagMenu: some View {
        MediaTagButton {
            let shouldResume = transport.wantsPlayback
            pausePlayback()
            resumePlaybackAfterTags = shouldResume
            showTagSheet = true
        }
    }

    // MARK: - Transport

    private var playerTime: Double? {
        guard let player else { return nil }
        let time = player.currentTime().seconds
        return time.isFinite ? time : nil
    }

    private func togglePlay() {
        guard let player else { return }
        scheduleControlsAutoHide(delay: 2.5)
        if transport.wantsPlayback {
            pausePlayback()
        } else {
            if isSeeking || isScrubbing {
                requestPlayback()
                return
            }
            // Position réelle du lecteur (l'état `currentTime` peut être
            // périmé : sa mise à jour est suspendue contrôles masqués).
            let position = player.currentTime().seconds
            let atEnd = clock.duration.isFinite && clock.duration > 0 && position >= clock.duration - 0.5
            if !atEnd {
                requestPlayback()
                return
            }
            // Reprise après la fin : le retour à zéro doit être effectif
            // AVANT de (re)lancer, sinon playImmediately repart de la fin.
            transport.play()
            transport.clearRecoveryPosition()
            seek(to: 0, precise: true)
        }
    }

    /// Une pause explicite ne détruit pas la recherche : sa position reste
    /// valable, mais son callback n'a plus le droit de relancer la lecture.
    private func pausePlayback() {
        transport.pause()
        resumePlaybackAfterTags = false
        player?.pause()
        // Le watchdog peut déjà être en train de remplacer le lecteur : le
        // laisser terminer en pause évite de rester sans lecteur ni erreur.
        if player != nil { cancelStallWatchdog() }
    }

    private func requestPlayback() {
        guard scenePhase == .active, isActive, !isDisappeared, !showTagSheet else { return }
        transport.play()
        resumePlaybackIfRequested()
    }

    private func resumePlaybackIfRequested() {
        guard scenePhase == .active, transport.wantsPlayback, !isScrubbing, !isSeeking,
              isActive, !isDisappeared, !showTagSheet, let player else { return }
        player.playImmediately(atRate: playbackRate)
    }

    private func seek(to seconds: Double, precise: Bool = false) {
        guard let player else { return }
        // Tolérance volontairement non nulle même en « précis » : sur un flux
        // réseau, une tolérance zéro force le décodage de l'image exacte et
        // prolonge le gel après chaque scrub. Une demi-seconde reste invisible
        // à l'œil tout en rendant la reprise quasi immédiate.
        let tolerance: CMTime = precise
            ? CMTime(seconds: 0.4, preferredTimescale: 600)
            : .positiveInfinity
        let target: Double
        if clock.duration.isFinite, clock.duration > 0 {
            target = min(max(seconds, 0), clock.duration)
        } else {
            target = max(seconds, 0)
        }
        let requestID = transport.beginSeek()
        clock.scrubValue = target
        // Un seek antérieur peut encore être en cours après deux relâchements
        // rapides. On le remplace explicitement par la dernière intention.
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak player] finished in
            Task { @MainActor in
                guard let player,
                      transport.acceptsSeek(requestID),
                      self.player === player,
                      !isDisappeared
                else { return }

                let resolvedTime = player.currentTime().seconds
                if resolvedTime.isFinite {
                    clock.currentTime = resolvedTime
                    clock.scrubValue = resolvedTime
                } else if finished {
                    clock.currentTime = target
                    clock.scrubValue = target
                }
                let shouldResume = transport.finishSeek(requestID, finished: finished)
                if finished { transport.clearRecoveryPosition() }
                scheduleControlsAutoHide(delay: 2.5)

                // L'intention actuelle prime, même si elle a changé pendant
                // la recherche. À la fin, le bouton propose de rejouer.
                let nearEnd = clock.duration.isFinite && clock.duration > 0 && target >= clock.duration - 0.5
                if nearEnd {
                    pausePlayback()
                } else if shouldResume {
                    resumePlaybackIfRequested()
                }
            }
        }
    }

    /// Annule une recherche lancée au relâchement précédent et invalide son
    /// callback. Cette opération est aussi exécutée au début d'un nouveau drag.
    private func cancelPendingSeek() {
        transport.cancelSeek()
        player?.currentItem?.cancelPendingSeeks()
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player?.defaultRate = rate
        if transport.wantsPlayback, !isScrubbing, !isSeeking {
            player?.rate = rate
        }
        scheduleControlsAutoHide(delay: 2.5)
    }

    // MARK: - Favori & tags

    private func toggleFavorite() async {
        guard !isFavoriteMutationInProgress else { return }
        isFavoriteMutationInProgress = true
        defer { isFavoriteMutationInProgress = false }
        let newValue = !isFavorite
        isFavorite = newValue
        do {
            try await service.setFavorite(driveId: driveId, fileId: file.id, favorite: newValue)
            FileGridMutationCenter.shared.publish(
                .favorite(driveId: driveId, fileId: file.id, isFavorite: newValue)
            )
        } catch {
            isFavorite = !newValue
            errorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Chargement

    private func load() async {
        // Retour sur une page encore en mémoire : le lecteur existe, on
        // reprend simplement la lecture.
        if player != nil {
            requestPlayback()
            return
        }
        if recoveryPosition == nil, scenePhase == .active { transport.play() }
        isLoadingVideo = true
        hasFailedSetup = false
        loadGeneration += 1
        let generation = loadGeneration
        // Seule la génération la plus récente possède le drapeau : une charge
        // annulée qui se termine tardivement ne le relâche pas à sa place.
        defer {
            if loadGeneration == generation {
                isLoadingVideo = false
            }
        }

        // Tâche non structurée qui s'auto-assigne dès son achèvement : le
        // poster s'affiche pendant la résolution de l'asset, sans retarder
        // ni l'un ni l'autre. Inutile si le poster est déjà affiché (retour
        // sur une page gardée en mémoire).
        if poster == nil {
            Task {
                // La miniature réutilise le poster déjà en cache mémoire
                // au lieu d'une requête réseau distincte qui ferait la file
                // derrière les autres téléchargements.
                let image = await ThumbnailProvider.shared.thumbnail(
                    driveId: driveId,
                    fileId: file.id
                )
                guard !isDisappeared, poster == nil else { return }
                poster = image
            }
        }

        // La vidéo active est prioritaire : les préchargements de miniatures
        // (jusqu'à 8 téléchargements simultanés) partagent la session réseau
        // et retardent le `moov` + les premiers segments. Le poster direct
        // (cache mémoire/disque) n'est pas concerné, ni les URL vidéo (2 max).
        await ThumbnailProvider.shared.cancelPrefetch()
        // La ressource authentifiée peut déjà avoir été préparée juste avant
        // le tap. Le poster ne retarde jamais le lecteur.
        let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id)

        // Swipe hors page ou fermeture : la tâche porteuse est annulée ou la
        // page est disparue. Ce n'est pas un échec — on sort sans état d'erreur
        // pour que la prochaine génération de `.task(id:)` recharge sereinement
        // (l'ancienne tâche ne doit jamais créer de lecteur ni alerter).
        guard generation == loadGeneration, isActive,
              !isDisappeared, !Task.isCancelled else { return }
        guard let asset else {
            hasFailedSetup = true
            errorMessage = "Impossible de préparer cette vidéo. Vérifiez votre connexion puis réessayez."
            return
        }

        startPlayback(asset: asset, at: recoveryPosition)
    }

    private func startPlayback(asset: AVURLAsset, at resumePosition: Double? = nil) {
        // Dernier verrou anti-double-lecture : si un lecteur existe déjà
        // (chargement concurrent gagnant la course), ne rien créer du tout.
        guard player == nil else { return }
        cancelPendingSeek()
        transport.reset(preservingPlaybackIntent: true)
        let newItem = AVPlayerItem(asset: asset)
        // Réserve aval adaptative : 10 s seulement quand on SAIT qu'on n'est
        // pas sur Wi-Fi. Trente secondes de 4K pèsent lourd en mémoire et en
        // données ; sur une connexion contrainte, c'est le tampon lui-même qui
        // affame le démarrage et évince les miniatures. En cas de doute
        // (état réseau pas encore connu à l'ouverture), on suppose le Wi-Fi
        // pour ne pas brider la première vidéo.
        newItem.preferredForwardBufferDuration = NetworkMonitor.shared.isKnownNonWiFi ? 10 : 30
        let newPlayer = AVPlayer(playerItem: newItem)
        // Démarrage immédiat dès les premières frames disponibles : avec
        // playImmediately, attendre le buffer « sûr » ajoute jusqu'à ~2 s
        // avant la première image. Le poster masque une éventuelle micro-saccade,
        // et la réserve aval ci-dessus absorbe les creux de débit ensuite.
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.isMuted = isMuted
        newPlayer.defaultRate = playbackRate
        newPlayer.allowsExternalPlayback = true
        newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true

        guard isActive, !isDisappeared, !Task.isCancelled else {
            newPlayer.pause()
            return
        }
        // Session retenue seulement si le lecteur démarre vraiment : chaque
        // `retain` est apparié au `release` du teardown correspondant.
        AudioSessionKeeper.shared.retain()
        player = newPlayer
        retryResetPosition = resumePosition ?? 0
        addObservers(to: newPlayer)
        if let resumePosition, resumePosition.isFinite, resumePosition > 0 {
            // Même mécanisme que le scrub : une pause ou un nouveau geste
            // peut préempter la reprise après une erreur réseau.
            clock.currentTime = resumePosition
            clock.scrubValue = resumePosition
            seek(to: resumePosition, precise: true)
        } else {
            clock.currentTime = 0
            clock.scrubValue = 0
            // Pas de seek : la lecture démarre déjà à zéro, un seek à tolérance
            // nulle forcerait une préparation précise avant la première frame.
            transport.clearRecoveryPosition()
            resumePlaybackIfRequested()
        }

        itemStatusObserver = newPlayer.currentItem?.observe(\.status, options: [.new]) { item, _ in
            // Être prêt ne prouve pas que la reprise fonctionne : le quota
            // est réinitialisé seulement après une progression réelle.
            if item.status == .readyToPlay {
                Task { @MainActor in
                    guard self.player?.currentItem === item, !isDisappeared else { return }
                    hasFailedSetup = false
                }
            }
            guard item.status == .failed else { return }
            Task { @MainActor in
                await self.retryPlaybackAfterProcessingDelay(
                    failedItem: item,
                    lastError: item.error?.localizedDescription ?? "la vidéo n’est pas disponible"
                )
            }
        }
    }

    /// Après un upload, le fichier peut être listé avant d'être servi par le
    /// endpoint de téléchargement. Deux nouvelles tentatives suffisent à
    /// absorber ce court délai sans demander une action manuelle.
    private func retryPlaybackAfterProcessingDelay(failedItem: AVPlayerItem, lastError: String) async {
        guard !isDisappeared, isActive else { return }
        // La relance ne vaut que si l'item fautif est toujours celui du lecteur
        // courant : un swipe hors page puis un retour ont pu recréer un lecteur
        // entre l'échec et ce réveil. Le remplacer donnerait deux AVPlayer en
        // lecture simultanée, avec des observateurs écrasés jamais invalidés.
        guard player?.currentItem === failedItem else { return }
        guard playbackRetryCount < 2 else {
            failPlayback(message: "Lecture impossible : \(lastError)")
            return
        }

        playbackRetryCount += 1
        await recoverPlayback(
            after: .seconds(playbackRetryCount * 2),
            failureMessage: "Lecture impossible : \(lastError)"
        )
    }

    private func rememberRecoveryPosition() {
        // Un item de remplacement peut échouer avant d'avoir rejoint la position
        // initiale : ne pas remplacer celle-ci par son temps de départ (zéro).
        guard recoveryPosition == nil else { return }
        let position = isScrubbing || isSeeking ? clock.scrubValue : (playerTime ?? clock.currentTime)
        transport.rememberRecoveryPosition(position)
    }

    private func failPlayback(message: String) {
        rememberRecoveryPosition()
        teardown(preservingPlaybackIntent: true)
        hasFailedSetup = true
        errorMessage = message
        showControls = true
    }

    private func recoverPlayback(
        after delay: Duration,
        failureMessage: String,
        fromStallWatchdog: Bool = false
    ) async {
        rememberRecoveryPosition()
        teardown(cancelsStallWatchdog: !fromStallWatchdog, preservingPlaybackIntent: true)
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoadingVideo = true
        hasFailedSetup = false
        defer {
            if generation == loadGeneration { isLoadingVideo = false }
        }
        VideoAssetCache.shared.invalidate(driveId: driveId, fileId: file.id)
        do {
            try await Task.sleep(for: delay)
        } catch { return }
        guard generation == loadGeneration, isActive,
              !isDisappeared, !Task.isCancelled else { return }
        // Même priorité qu'au chargement initial : la récupération après stall
        // a besoin de toute la bande passante pour refaire son tampon.
        await ThumbnailProvider.shared.cancelPrefetch()
        let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id)
        guard generation == loadGeneration, isActive,
              !isDisappeared, !Task.isCancelled, player == nil else { return }
        guard let asset else {
            hasFailedSetup = true
            errorMessage = failureMessage
            return
        }
        startPlayback(asset: asset, at: recoveryPosition)
    }

    private func updateTimeObserver(for player: AVPlayer) {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            // Le chrome suit à 4 Hz quand il est visible : un label à la seconde
            // près et une barre de progression n'ont pas besoin de 8 images/s,
            // et chaque tick reconstruit la vue sur le main. Caché, seul le
            // suivi opérationnel (récupération/AirPlay) reste actif à 1 Hz.
            forInterval: CMTime(value: 1, timescale: showControls ? 4 : 1),
            queue: .main
        ) { time in
            guard self.player === player, !isDisappeared else { return }
            if playbackRetryCount > 0, !isScrubbing, !isSeeking,
               player.timeControlStatus == .playing,
               time.seconds.isFinite, time.seconds >= retryResetPosition + 2 {
                playbackRetryCount = 0
            }
            let externalPlaybackActive = player.isExternalPlaybackActive
            if isExternalPlaybackActive != externalPlaybackActive {
                isExternalPlaybackActive = externalPlaybackActive
            }
            guard showControls else { return }
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            if itemDuration.isFinite, itemDuration > 0,
               abs(clock.duration - itemDuration) > 0.01 {
                clock.duration = itemDuration
            }
            if !isScrubbing, !isSeeking, showControls, time.seconds.isFinite {
                clock.currentTime = time.seconds
            }
            // Plage bufferisée : fin la plus avancée des segments chargés —
            // après un seek en avant, le segment contenant la position peut
            // ne pas exister encore ; prendre le premier intervalle afficherait
            // un buffer résiduel derrière le curseur. Borné à la durée.
            let ranges = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue) ?? []
            if !ranges.isEmpty {
                let rawEnd = ranges.map(\.end.seconds).max() ?? 0
                let clampedEnd = clock.duration.isFinite && clock.duration > 0
                    ? min(rawEnd, clock.duration)
                    : rawEnd
                if abs(clock.bufferedEnd - clampedEnd) > 0.05 {
                    clock.bufferedEnd = max(0, clampedEnd)
                }
            } else if clock.bufferedEnd != 0 {
                clock.bufferedEnd = 0
            }
        }
    }

    private func addObservers(to player: AVPlayer) {
        updateTimeObserver(for: player)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            if !isScrubbing, !isSeeking { transport.pause() }
        }
        // Les pauses techniques des seeks ne modifient jamais l'intention.
        // Les pauses utilisateur/système passent par pausePlayback().
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
            Task { @MainActor in
                guard self.player === observedPlayer, !isDisappeared else { return }
                switch observedPlayer.timeControlStatus {
                case .playing:
                    isBuffering = false
                    cancelStallWatchdog()
                    // Le démarrage rapide (`automaticallyWaits = false`) a rempli
                    // son rôle dès la première image : on rebascule en mode stable
                    // pour la suite, sinon chaque creux de débit fige au lieu
                    // d'attendre un tampon sûr — puis finit en watchdog 20 s.
                    if !observedPlayer.automaticallyWaitsToMinimizeStalling {
                        observedPlayer.automaticallyWaitsToMinimizeStalling = true
                    }
                case .waitingToPlayAtSpecifiedRate:
                    isBuffering = true
                    // Un tampon qui ne se remplit pas ne lèvera jamais
                    // `.failed` : seul un chronomètre détecte ce gel.
                    startStallWatchdog(player: observedPlayer)
                case .paused:
                    isBuffering = false
                    cancelStallWatchdog()
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Watchdog anti-stall

    /// Attente prolongée (> 20 s, image figée) : le lien signé a pu expirer
    /// ou le réseau rester coupé. On relance avec une URL fraîche, comme un
    /// échec explicite — au lieu d'un spinner éternel.
    private func startStallWatchdog(player: AVPlayer) {
        cancelStallWatchdog()
        let stalledItem = player.currentItem
        stallWatchdogTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            // Toujours en attente sur le même item ? (un seek ou une pause
            // aurait changé l'état et annulé cette tâche)
            guard !isDisappeared, isActive,
                  player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  player.currentItem === stalledItem
            else { return }
            // Quota partagé avec le retry d'échec : sans lui, un réseau mort
            // ferait tourner la récupération en boucle toutes les 20 s. Le
            // compteur est remis à zéro dès que la lecture repart vraiment.
            guard playbackRetryCount < 2 else {
                failPlayback(message: "Lecture interrompue trop longtemps. Vérifiez votre connexion puis réessayez.")
                return
            }
            playbackRetryCount += 1
            await recoverPlayback(
                after: .zero,
                failureMessage: "Lecture interrompue trop longtemps. Vérifiez votre connexion puis réessayez.",
                fromStallWatchdog: true
            )
        }
    }

    private func cancelStallWatchdog() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
    }

    /// Détruit lecteur et observateurs. `cancelsStallWatchdog` est faux quand
    /// le teardown est déclenché PAR le watchdog (récupération de stall) :
    /// il ne doit pas tuer la tâche de récupération en cours.
    private func teardown(cancelsStallWatchdog: Bool = true, preservingPlaybackIntent: Bool = false) {
        cancelPendingSeek()
        if cancelsStallWatchdog {
            cancelStallWatchdog()
        }
        transport.reset(preservingPlaybackIntent: preservingPlaybackIntent)
        if !preservingPlaybackIntent {
            resumePlaybackAfterTags = false
        }
        clock.bufferedEnd = 0
        liveSeekThrottle.reset()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        isBuffering = false
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        skipFeedbackResetTask?.cancel()
        skipFeedbackResetTask = nil
        // Une page qui n'a jamais créé de lecteur ne touche pas à la session :
        // une autre page du pager peut être en train de l'utiliser. La
        // désactivation est différée via le gardien : si une page voisine
        // démarre dans la seconde, la session reste active.
        if player != nil {
            player?.pause()
            player = nil
            AudioSessionKeeper.shared.release()
        }
    }

    // MARK: - Double-tap ±10 s

    /// Simple tap : la bascule des contrôles est différée de 250 ms, soit la
    /// fenêtre de désambiguïsation du double-tap. Un second tap annule
    /// l'attente et ne fait que sauter de 10 s : les contrôles ne bougent donc
    /// plus du tout, ni à l'aller ni au retour. Le rattrapage précédent les
    /// faisait disparaître puis revenir à chaque double-tap.
    private func handleVideoTap(at location: CGPoint) {
        let now = Date()
        let isDoubleTap = lastTapDate.map {
            now.timeIntervalSince($0) < 0.3
                && abs(location.x - lastTapLocation.x) < 44
                && abs(location.y - lastTapLocation.y) < 44
        } ?? false

        if isDoubleTap {
            pendingToggleTask?.cancel()
            pendingToggleTask = nil
            lastTapDate = nil
            guard player != nil, !hasFailedSetup, !isScrubbing, !isSeeking else { return }
            let onLeftHalf = location.x * 2 < videoAreaWidth
            // En RTL, l'avance se fait côté gauche (lecture inversée).
            let forward = layoutDirection == .rightToLeft ? onLeftHalf : !onLeftHalf
            skipTime(by: forward ? 10 : -10)
        } else {
            lastTapDate = now
            lastTapLocation = location
            pendingToggleTask?.cancel()
            pendingToggleTask = Task {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                pendingToggleTask = nil
                toggleControls()
            }
        }
    }

    private func skipTime(by delta: Double) {
        guard player != nil, !isScrubbing, !isSeeking else { return }
        // Source de vérité : la position réelle du lecteur (l'état peut être
        // périmé quand les contrôles sont masqués).
        let position = playerTime ?? clock.currentTime
        let upperBound = clock.duration.isFinite && clock.duration > 0 ? clock.duration : Double.infinity
        let target = min(max(position + delta, 0), upperBound)
        guard target != position else { return }
        transport.clearRecoveryPosition()
        // Le seek conserve l'intention de lecture/pause courante.
        seek(to: target, precise: false)
        showSkipFeedback(delta < 0 ? .backward : .forward)
    }

    private func showSkipFeedback(_ direction: SkipDirection) {
        withAnimation(Motion.animation(.snappy(duration: 0.15))) {
            skipFeedback = direction
        }
        skipFeedbackResetTask?.cancel()
        skipFeedbackResetTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.animation(.easeOut(duration: 0.25))) {
                skipFeedback = nil
            }
        }
    }

    /// Pastille « ±10 s » : cercle avec chevrons + libellé, côté tapé.
    @ViewBuilder
    private var skipFeedbackOverlay: some View {
        if let direction = skipFeedback {
            VStack(spacing: 6) {
                Image(systemName: direction == .forward ? "goforward.10" : "gobackward.10")
                    .font(.system(size: 34, weight: .medium))
                Text(direction == .forward ? "10 secondes" : "-10 secondes")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(.black.opacity(0.45), in: Circle())
            .offset(x: skipFeedbackOffset(for: direction))
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    /// La pastille apparaît côté tapé ; en RTL, les côtés s'inversent.
    private func skipFeedbackOffset(for direction: SkipDirection) -> CGFloat {
        let forwardOffset: CGFloat = 90
        let backwardOffset: CGFloat = -90
        let base = direction == .forward ? forwardOffset : backwardOffset
        return layoutDirection == .rightToLeft ? -base : base
    }

    // MARK: - Format

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        // Au-delà d'une heure : h:mm:ss (sinon « 75:00 » pour 1 h 15).
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
/// Barre de temps du lecteur : position courante, glissière et durée.
///
/// Vue séparée volontairement : elle est la **seule** à lire l'horloge de
/// transport (`PlaybackClock`). L'observateur périodique d'AVPlayer écrit la
/// position quatre fois par seconde pendant la lecture ; avec ces valeurs dans
/// le `@State` du lecteur, chaque tick reconstruisait toute la page (barre du
/// haut, boutons, zone vidéo et couche `AVPlayerLayer`). Ici, seuls les deux
/// compteurs et la glissière se rafraîchissent.
private struct TransportTimeView: View {
    let clock: PlaybackClock
    let isScrubbing: Bool
    let isSeeking: Bool
    let timeFormatter: (Double) -> String
    let onDragStarted: () -> Void
    let onDragChanged: (Double) -> Void
    let onDragEnded: (Double) -> Void
    let onDragCancelled: () -> Void

    /// Position affichée : celle du doigt pendant un glissement ou une
    /// recherche en cours, la position de lecture sinon.
    private var displayedTime: Double {
        isScrubbing || isSeeking ? clock.scrubValue : clock.currentTime
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(timeFormatter(displayedTime))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .scaleEffect(isScrubbing ? 1.18 : 1, anchor: .trailing)
                .contentTransition(.numericText())
                .animation(Motion.animation(.snappy(duration: 0.2)), value: Int(displayedTime))
                .frame(minWidth: 34, alignment: .trailing)

            ScrubberBar(
                position: displayedTime,
                duration: clock.duration,
                bufferedEnd: clock.bufferedEnd,
                isScrubbing: isScrubbing,
                timeFormatter: timeFormatter,
                onDragStarted: onDragStarted,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded,
                onDragCancelled: onDragCancelled
            )

            Text(timeFormatter(clock.duration))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .scaleEffect(isScrubbing ? 1.18 : 1, anchor: .leading)
                .contentTransition(.numericText())
                .animation(Motion.animation(.snappy(duration: 0.2)), value: Int(clock.duration))
                .frame(minWidth: 34, alignment: .leading)
        }
    }
}
