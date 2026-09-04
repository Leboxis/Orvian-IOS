import SwiftUI
import AVFoundation
import AVKit
import UIKit

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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var player: AVPlayer?
    @State private var poster: UIImage?

    // Transport
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    /// Une recherche AVPlayer est asynchrone : tant qu'elle n'est pas terminée,
    /// le curseur doit rester sur la position demandée, pas sur l'ancienne
    /// position remontée par l'observateur périodique.
    @State private var isSeeking = false
    @State private var scrubValue: Double = 0
    /// Identifie l'intention de seek la plus récente. Un callback retardé d'un
    /// seek annulé ne peut ainsi jamais écraser une position plus récente.
    @State private var seekRequestID = 0
    @State private var playbackRate: Float = 1

    // Son
    @State private var isMuted = false

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
    @State private var routeChangeObserver: NSObjectProtocol?
    @State private var itemStatusObserver: NSKeyValueObservation?
    /// Observation du `timeControlStatus` : source unique de vérité pour
    /// distinguer une vraie pause d'une mise en mémoire tampon (stall).
    @State private var timeControlStatusObserver: NSKeyValueObservation?
    /// Vrai pendant qu'AVPlayer attend des données (image figée ≠ pause) :
    /// l'état `isPlaying` est conservé et un indicateur s'affiche.
    @State private var isBuffering = false
    /// Watchdog anti-stall : un `.waiting` qui dépasse ~20 s (lien signé
    /// expiré en cours de lecture, réseau coupé) ne produit jamais `.failed`,
    /// il faut donc le détecter soi-même et relancer.
    @State private var stallWatchdogTask: Task<Void, Never>?
    /// État de lecture mémorisé au début d'un scrub : le seek relance la
    /// lecture à l'issue s'il était en cours, au lieu de laisser la vidéo en
    /// pause après le déplacement du curseur.
    @State private var wasPlayingBeforeScrub = false
    /// Fin de la plage bufferisée (pour la zone grisée du scrubber).
    @State private var bufferedEnd: Double = 0
    /// Anti-débounce des seeks « live » pendant le drag : la vidéo suit le
    /// doigt via des seeks grossiers, au plus un toutes les 100 ms.
    @State private var lastLiveSeekAt = Date.distantPast
    @State private var playbackRetryCount = 0
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

    // Copie du titre : pastille « Copié » brève après le tap.
    @State private var titleCopied = false
    @State private var titleCopyResetTask: Task<Void, Never>?

    // Rebond visuel du double-tap : pastille « ±10 s » brève du côté tapé.
    @State private var skipFeedback: SkipDirection?
    @State private var skipFeedbackResetTask: Task<Void, Never>?

    // Désambiguïsation manuelle simple/double tap (fenêtre 300 ms).
    @State private var lastTapDate: Date?
    @State private var lastTapLocation: CGPoint = .zero

    private let service = KDriveService()

    init(file: DriveFile, driveId: Int, isActive: Bool = true) {
        self.file = file
        self.driveId = driveId
        self.isActive = isActive
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

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)
            .animation(.easeInOut(duration: 0.25), value: showControls)
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
                // Si le lecteur existe encore (page restée en mémoire), on
                // reprend simplement la lecture ; sinon le `.task(id:)`
                // déclenché par le même changement s'occupe de (re)charger.
                if let player {
                    if !isPlaying {
                        player.playImmediately(atRate: playbackRate)
                        isPlaying = true
                    }
                }
            } else {
                // Page quittée : la lecture s'arrête, le lecteur reste prêt.
                hideControlsTask?.cancel()
                player?.pause()
                isPlaying = false
            }
        }
        .onDisappear {
            isDisappeared = true
            hideControlsTask?.cancel()
            teardown()
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
                if let player {
                    player.playImmediately(atRate: playbackRate)
                    isPlaying = true
                }
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

    private func scheduleControlsAutoHide(delay: Double = 2.5) {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if !isScrubbing, !isSeeking {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.25)) {
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
            titleArea
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

    /// Même titre copiable et même accusé visuel que dans la visionneuse
    /// d'image.
    private var titleArea: some View {
        Group {
            if titleCopied {
                Label("Copié", systemImage: "doc.on.doc")
                    .font(.footnote.weight(.medium))
            } else {
                Text(file.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.25), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            UIPasteboard.general.string = file.name
            titleCopied = true
            scheduleTitleCopyReset()
        }
        .padding(.horizontal, UIScreen.main.bounds.width * 0.2)
        .frame(maxWidth: .infinity)
    }

    private func scheduleTitleCopyReset() {
        titleCopyResetTask?.cancel()
        titleCopyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                titleCopied = false
            }
        }
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

            Text(timeText(displayedTime))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .scaleEffect(isScrubbing ? 1.18 : 1, anchor: .trailing)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: Int(displayedTime))
                .frame(minWidth: 34, alignment: .trailing)

            ScrubberBar(
                position: displayedTime,
                duration: duration,
                bufferedEnd: bufferedEnd,
                isScrubbing: isScrubbing,
                timeFormatter: { timeText($0) },
                onDragStarted: beginScrub,
                onDragChanged: updateScrub(to:),
                onDragEnded: endScrub(to:)
            )

            Text(timeText(duration))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .scaleEffect(isScrubbing ? 1.18 : 1, anchor: .leading)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: Int(duration))
                .frame(minWidth: 34, alignment: .leading)

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
        hideControlsTask?.cancel()
        cancelPendingSeek()
        scrubValue = playerTime ?? currentTime
        // `.waitingToPlayAtSpecifiedRate` compte comme « en lecture » : un
        // scrub pendant une mise en mémoire tampon relance bien la vidéo.
        // La mémoire du geste précédent est conservée : son seek de reprise
        // vient d'être annulé par `cancelPendingSeek`, le lecteur est donc
        // encore en pause alors que la lecture devait reprendre — sans cela,
        // un second glissement rapproché terminait en pause toute seule.
        wasPlayingBeforeScrub = (player?.timeControlStatus != .paused) || wasPlayingBeforeScrub
        isScrubbing = true
        // Le son cesse pendant le geste : le suivi visuel sous le doigt
        // remplace la lecture (comportement natif).
        player?.pause()
    }

    private func updateScrub(to seconds: Double) {
        scrubValue = max(0, seconds)
        scheduleLiveScrubSeek(to: seconds)
    }

    /// Seek grossier throttlé : tolérance 1,5 s → AVPlayer saute au keyframe
    /// le plus proche et la couche vidéo principale suit le doigt sans
    /// attendre l'image exacte (le seek final précis intervient au relâchement).
    private func scheduleLiveScrubSeek(to seconds: Double) {
        guard let player else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLiveSeekAt) >= 0.1 else { return }
        lastLiveSeekAt = now
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(
            to: target,
            toleranceBefore: CMTime(seconds: 1.5, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 1.5, preferredTimescale: 600)
        )
    }

    private func endScrub(to seconds: Double) {
        isScrubbing = false
        lastLiveSeekAt = .distantPast
        // Seek final précis + reprise conditionnelle (déjà gérés par `seek`).
        seek(to: seconds, precise: true)
    }

    // MARK: - Boutons

    private var playButton: some View {
        Button {
            togglePlay()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
        }
        .disabled(player == nil)
        .accessibilityLabel(isPlaying ? "Pause" : "Lecture")
    }

    private var favoriteButton: some View {
        Button {
            Task { await toggleFavorite() }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFavorite ? .yellow : .white)
                .frame(width: 30, height: 30)
        }
        .disabled(isFavoriteMutationInProgress)
        .accessibilityLabel(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
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
        Button {
            resumePlaybackAfterTags = player != nil
                && (isPlaying || player?.timeControlStatus == .playing)
            player?.pause()
            showTagSheet = true
        } label: {
            Image(systemName: "tag")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel("Appliquer un tag")
    }

    // MARK: - Transport

    private var displayedTime: Double {
        isScrubbing || isSeeking ? scrubValue : currentTime
    }

    private var playerTime: Double? {
        guard let player else { return nil }
        let time = player.currentTime().seconds
        return time.isFinite ? time : nil
    }

    private func togglePlay() {
        guard let player else { return }
        scheduleControlsAutoHide(delay: 2.5)
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Position réelle du lecteur (l'état `currentTime` peut être
            // périmé : sa mise à jour est suspendue contrôles masqués).
            let position = player.currentTime().seconds
            let atEnd = duration.isFinite && duration > 0 && position >= duration - 0.5
            if !atEnd {
                player.playImmediately(atRate: playbackRate)
                isPlaying = true
                return
            }
            // Reprise après la fin : le retour à zéro doit être effectif
            // AVANT de (re)lancer, sinon playImmediately repart de la fin.
            currentTime = 0
            scrubValue = 0
            player.seek(to: .zero) { [weak player] _ in
                Task { @MainActor in
                    guard let player, self.player === player, !isDisappeared else { return }
                    player.playImmediately(atRate: playbackRate)
                    isPlaying = true
                }
            }
        }
    }

    private func seek(to seconds: Double, precise: Bool = false) {
        guard let player else { return }
        // Tolérance volontairement non nulle même en « précis » : sur un flux
        // réseau, une tolérance zéro force le décodage de l'image exacte et
        // prolonge le gel après chaque scrub. Une demi-seconde reste invisible
        // à l'œil tout en rendant la reprise quasi immédiate.
        let tolerance: CMTime = precise
            ? CMTime(seconds: 0.4, preferredTimescale: 600)
            : .indefinite
        let target: Double
        if duration.isFinite, duration > 0 {
            target = min(max(seconds, 0), duration)
        } else {
            target = max(seconds, 0)
        }
        seekRequestID &+= 1
        let requestID = seekRequestID
        isSeeking = true
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
                      requestID == seekRequestID,
                      self.player === player,
                      !isDisappeared
                else { return }

                let resolvedTime = player.currentTime().seconds
                if resolvedTime.isFinite {
                    currentTime = resolvedTime
                    scrubValue = resolvedTime
                } else if finished {
                    currentTime = target
                    scrubValue = target
                }
                isSeeking = false
                scheduleControlsAutoHide(delay: 2.5)

                // Reprise après un scrub : la lecture ne repart que si elle
                // était active avant le geste, et pas lorsque le curseur a
                // été relâché sur les dernières frames (la fin déclenchera
                // l'observateur de fin).
                let wasPlaying = wasPlayingBeforeScrub
                wasPlayingBeforeScrub = false
                let nearEnd = duration.isFinite && duration > 0 && target >= duration - 0.5
                if finished, wasPlaying, !nearEnd,
                   player.timeControlStatus != .playing {
                    player.playImmediately(atRate: playbackRate)
                    isPlaying = true
                }
            }
        }
    }

    /// Annule une recherche lancée au relâchement précédent et invalide son
    /// callback. Cette opération est aussi exécutée au début d'un nouveau drag.
    private func cancelPendingSeek() {
        seekRequestID &+= 1
        player?.currentItem?.cancelPendingSeeks()
        isSeeking = false
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player?.defaultRate = rate
        if isPlaying || player?.timeControlStatus == .playing {
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
        if let player {
            if !isPlaying {
                player.playImmediately(atRate: playbackRate)
                isPlaying = true
            }
            return
        }
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

        // La ressource authentifiée peut déjà avoir été préparée juste avant
        // le tap. Le poster ne retarde jamais le lecteur.
        let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id)

        // Swipe hors page ou fermeture : la tâche porteuse est annulée ou la
        // page est disparue. Ce n'est pas un échec — on sort sans état d'erreur
        // pour que la prochaine génération de `.task(id:)` recharge sereinement
        // (l'ancienne tâche ne doit jamais créer de lecteur ni alerter).
        guard !isDisappeared, !Task.isCancelled else { return }
        guard let asset else {
            hasFailedSetup = true
            errorMessage = "Impossible de préparer cette vidéo. Vérifiez votre connexion puis réessayez."
            return
        }

        startPlayback(asset: asset)
    }

    private func startPlayback(asset: AVURLAsset, at resumePosition: Double? = nil) {
        // Dernier verrou anti-double-lecture : si un lecteur existe déjà
        // (chargement concurrent gagnant la course), ne rien créer du tout.
        guard player == nil else { return }
        cancelPendingSeek()
        isScrubbing = false
        wasPlayingBeforeScrub = false
        let newItem = AVPlayerItem(asset: asset)
        // Garde ~30 s de vidéo en réserve : sans cette consigne, le tampon
        // aval par défaut se limite à quelques secondes et toute baisse de
        // débit provoque un gel (« 1 s puis stop ») au redémarrage suivant.
        newItem.preferredForwardBufferDuration = 30
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

        guard !isDisappeared, !Task.isCancelled else {
            newPlayer.pause()
            return
        }
        // Session retenue seulement si le lecteur démarre vraiment : chaque
        // `retain` est apparié au `release` du teardown correspondant.
        AudioSessionKeeper.shared.retain()
        player = newPlayer
        addObservers(to: newPlayer)
        if let resumePosition, resumePosition.isFinite, resumePosition > 0.1 {
            // Reprise après stall : retour à la position du gel. Tolérance
            // large : l'image exacte importe peu, la vitesse de reprise si.
            currentTime = resumePosition
            scrubValue = resumePosition
            newPlayer.seek(
                to: CMTime(seconds: resumePosition, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 1.5, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 1.5, preferredTimescale: 600)
            ) { [weak newPlayer] _ in
                Task { @MainActor in
                    guard let newPlayer, self.player === newPlayer, !isDisappeared else { return }
                    newPlayer.playImmediately(atRate: playbackRate)
                    isPlaying = true
                }
            }
        } else {
            currentTime = 0
            scrubValue = 0
            // Pas de seek : la lecture démarre déjà à zéro, un seek à tolérance
            // nulle forcerait une préparation précise avant la première frame.
            newPlayer.playImmediately(atRate: playbackRate)
            isPlaying = true
        }

        itemStatusObserver = newPlayer.currentItem?.observe(\.status, options: [.new]) { item, _ in
            // Lecture prête : le quota de tentatives repart de zéro pour
            // absorber un futur incident (ex. URL signée expirée en cours de
            // visionnage) au lieu d'hériter des échecs déjà récupérés.
            if item.status == .readyToPlay {
                Task { @MainActor in
                    guard !isDisappeared else { return }
                    playbackRetryCount = 0
                    hasFailedSetup = false
                }
            }            guard item.status == .failed else { return }
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
            isPlaying = false
            hasFailedSetup = true
            errorMessage = "Lecture impossible : \(lastError)"
            return
        }

        playbackRetryCount += 1
        isPlaying = false
        teardown()
        VideoAssetCache.shared.invalidate(driveId: driveId, fileId: file.id)

        do {
            try await Task.sleep(for: .seconds(playbackRetryCount * 2))
        } catch {
            return
        }
        // Un retour sur la page pendant le sommeil peut avoir relancé un
        // lecteur sain via `.task(id:)` : il ne doit jamais être écrasé ici.
        guard !isDisappeared, isActive, player == nil,
              let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id)
        else { return }
        startPlayback(asset: asset)
    }

    private func addObservers(to player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            // Huit mises à jour par seconde : visuellement identiques à 30
            // pour un curseur de progression, mais avec trois fois moins de
            // rendus SwiftUI pendant la lecture. Les mises à jour restent
            // suspendues quand les contrôles sont invisibles.
            forInterval: CMTime(value: 1, timescale: 8),
            queue: .main
        ) { time in
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            if itemDuration.isFinite, itemDuration > 0,
               abs(duration - itemDuration) > 0.01 {
                duration = itemDuration
            }
            if !isScrubbing, !isSeeking, showControls, time.seconds.isFinite {
                currentTime = time.seconds
            }
            // Plage bufferisée : fin la plus avancée des segments chargés —
            // après un seek en avant, le segment contenant la position peut
            // ne pas exister encore ; prendre le premier intervalle afficherait
            // un buffer résiduel derrière le curseur. Borné à la durée.
            let ranges = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue) ?? []
            if !ranges.isEmpty {
                let rawEnd = ranges.map(\.end.seconds).max() ?? 0
                let clampedEnd = duration.isFinite && duration > 0 ? min(rawEnd, duration) : rawEnd
                if abs(bufferedEnd - clampedEnd) > 0.05 {
                    bufferedEnd = max(0, clampedEnd)
                }
            } else if bufferedEnd != 0 {
                bufferedEnd = 0
            }
            // `isPlaying` n'est PAS déduit ici : `.waitingToPlayAtSpecifiedRate`
            // (mise en mémoire tampon) n'est pas une pause, et traiter ce cas
            // comme un arrêt faisait repasser le bouton en « Play » puis
            // rejouait l'unique seconde bufferisée à chaque tap — boucle de
            // gel. Le KVO ci-dessous fait foi.
            let externalPlaybackActive = player.isExternalPlaybackActive
            if isExternalPlaybackActive != externalPlaybackActive {
                isExternalPlaybackActive = externalPlaybackActive
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
        }
        // Casque/enceinte Bluetooth débranché : pause immédiate, comme les
        // apps Apple. Le son ne doit jamais basculer sur le haut-parleur.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak player] notification in
            guard let player else { return }
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let reason = reasonRaw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)),
                  reason == .oldDeviceUnavailable
            else { return }
            Task { @MainActor in
                guard self.player === player, !isDisappeared else { return }
                player.pause()
                isPlaying = false
            }
        }
        // Source unique de vérité lecture/pause/buffering : `.waiting` garde
        // `isPlaying` tel quel et affiche l'indicateur au lieu de simuler
        // une pause. Pas d'option `.initial` : l'état de départ est posé par
        // `startPlayback`, et une tâche retardée ne doit jamais l'écraser.
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
            Task { @MainActor in
                guard self.player === observedPlayer, !isDisappeared else { return }
                switch observedPlayer.timeControlStatus {
                case .playing:
                    isBuffering = false
                    isPlaying = true
                    cancelStallWatchdog()
                case .waitingToPlayAtSpecifiedRate:
                    isBuffering = true
                    // Un tampon qui ne se remplit pas ne lèvera jamais
                    // `.failed` : seul un chronomètre détecte ce gel.
                    startStallWatchdog(player: observedPlayer)
                case .paused:
                    isBuffering = false
                    isPlaying = false
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
            // La position de gel est celle du curseur : le temps n'avance
            // plus pendant l'attente. La reprise y reviendra.
            let resumePosition = player.currentTime().seconds
            // Quota partagé avec le retry d'échec : sans lui, un réseau mort
            // ferait tourner la récupération en boucle toutes les 20 s. Le
            // compteur est remis à zéro dès que la lecture repart vraiment.
            guard playbackRetryCount < 2 else {
                isPlaying = false
                isBuffering = false
                teardown()
                hasFailedSetup = true
                errorMessage = "Lecture interrompue trop longtemps. Vérifiez votre connexion puis réessayez."
                return
            }
            playbackRetryCount += 1
            isPlaying = false
            isBuffering = false
            // Ne pas s'auto-annuler : ce teardown est appelé depuis la tâche
            // du watchdog elle-même.
            teardown(cancelsStallWatchdog: false)
            VideoAssetCache.shared.invalidate(driveId: driveId, fileId: file.id)
            guard let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id)
            else {
                hasFailedSetup = true
                errorMessage = "Lecture interrompue trop longtemps. Vérifiez votre connexion puis réessayez."
                return
            }
            startPlayback(asset: asset, at: resumePosition.isFinite ? resumePosition : nil)
        }
    }

    private func cancelStallWatchdog() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
    }

    /// Détruit lecteur et observateurs. `cancelsStallWatchdog` est faux quand
    /// le teardown est déclenché PAR le watchdog (récupération de stall) :
    /// il ne doit pas tuer la tâche de récupération en cours.
    private func teardown(cancelsStallWatchdog: Bool = true) {
        cancelPendingSeek()
        if cancelsStallWatchdog {
            cancelStallWatchdog()
        }
        isScrubbing = false
        wasPlayingBeforeScrub = false
        bufferedEnd = 0
        lastLiveSeekAt = .distantPast
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
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
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

    /// Simple tap instantané : bascule les contrôles, sauf si un tap très
    /// rapproché au même endroit révèle un double-tap — alors la bascule est
    /// annulée (rattrapage) et remplacée par le saut de 10 s.
    private func handleVideoTap(at location: CGPoint) {
        let now = Date()
        let isDoubleTap = lastTapDate.map {
            now.timeIntervalSince($0) < 0.3
                && abs(location.x - lastTapLocation.x) < 44
                && abs(location.y - lastTapLocation.y) < 44
        } ?? false

        if isDoubleTap {
            // Second tap d'un double : annule l'effet du premier tap.
            cancelPendingToggle()
            lastTapDate = nil
            guard player != nil, !hasFailedSetup, !isScrubbing, !isSeeking else { return }
            let onLeftHalf = location.x * 2 < videoAreaWidth
            // En RTL, l'avance se fait côté gauche (lecture inversée).
            let forward = layoutDirection == .rightToLeft ? onLeftHalf : !onLeftHalf
            skipTime(by: forward ? 10 : -10)
        } else {
            lastTapDate = now
            lastTapLocation = location
            toggleControls()
        }
    }

    /// Retour visuel si le premier tap d'un double a masqué les contrôles.
    private func cancelPendingToggle() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = true
        }
        scheduleControlsAutoHide(delay: 2.5)
    }

    private func skipTime(by delta: Double) {
        guard let player, !isScrubbing, !isSeeking else { return }
        // Source de vérité : la position réelle du lecteur (l'état peut être
        // périmé quand les contrôles sont masqués).
        let position = playerTime ?? currentTime
        let upperBound = duration.isFinite && duration > 0 ? duration : Double.infinity
        let target = min(max(position + delta, 0), upperBound)
        guard target != position else { return }
        // `seek` relance la lecture si elle tournait (mémoire
        // `wasPlayingBeforeScrub`) et reste en pause sinon — comportement natif.
        wasPlayingBeforeScrub = player.timeControlStatus != .paused
        seek(to: target, precise: false)
        showSkipFeedback(delta < 0 ? .backward : .forward)
    }

    private func showSkipFeedback(_ direction: SkipDirection) {
        withAnimation(.snappy(duration: 0.15)) {
            skipFeedback = direction
        }
        skipFeedbackResetTask?.cancel()
        skipFeedbackResetTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
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

// MARK: - Vues UIKit embarquées

/// Sens du saut déclenché par le double-tap (pilote la pastille de rebond).
private enum SkipDirection {
    case forward
    case backward
}

/// Vitesses de lecture proposées par la pastille en bas à droite.
private enum SpeedOption: Float, CaseIterable, Identifiable {
    case slow = 0.5
    case threeQuarters = 0.75
    case normal = 1.0
    case oneAndQuarter = 1.25
    case oneAndHalf = 1.5
    case double = 2.0

    var id: Float { rawValue }
    var rate: Float { rawValue }

    var title: String {
        let value = rawValue
        if value == value.rounded() { return "\(Int(value))x" }
        return String(format: "%gx", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Couche de rendu AVPlayerLayer (sans contrôles natifs).
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {}

    final class PlayerLayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Bouton AirPlay natif (AVRoutePickerView), teinté en blanc.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Référence comptée sur la session audio : chaque lecteur actif la retient,
/// la désactivation ne survient que lorsque le dernier la relâche. Évite
/// qu'une page voisine du pager (qui vient de détruire son lecteur) ne coupe
/// la session d'une page encore en lecture. La désactivation notifie les
/// autres apps pour que leur musique reprenne.
@MainActor
private final class AudioSessionKeeper {
    static let shared = AudioSessionKeeper()

    private var retainCount = 0
    /// Désactivation différée : une page voisine qui démarre dans la seconde
    /// annule la libération en retenant la session.
    private var pendingReleaseTask: Task<Void, Never>?

    private init() {}

    func retain() {
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
        if retainCount == 0 {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
                try session.setActive(true)
            } catch {
                try? session.setCategory(.playback, mode: .moviePlayback)
                try? session.setActive(true)
            }
        }
        retainCount += 1
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        guard retainCount == 0 else { return }
        pendingReleaseTask?.cancel()
        pendingReleaseTask = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }
}
