import SwiftUI
import AVFoundation
import AVKit

/// Lecteur vidéo personnalisé : les barres (titre + boutons en haut,
/// transport en bas) sont hors de la zone de lecture de la vidéo.
/// Haut : AirPlay (RP), tag, favori à gauche — muet + fermer à droite.
/// Bas : play/pause, progression agrandie, vitesse de lecture.
struct VideoPlayerView: View {
    let file: DriveFile
    let driveId: Int
    /// Vrai quand la page est l'élément courant d'un pager : seule la page
    /// active charge et lit la vidéo. Toujours vrai quand le lecteur est
    /// présenté seul (visionneuse directe).
    let isActive: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var poster: UIImage?

    // Transport
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var playbackRate: Float = 1

    // Son
    @State private var isMuted = false

    // Favori
    @State private var isFavorite: Bool

    // Tags
    @State private var categories: [Category] = []
    @State private var appliedCategoryIds: Set<Int>

    @State private var errorMessage: String?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var itemStatusObserver: NSKeyValueObservation?
    @State private var playbackRetryCount = 0
    @State private var isDisappeared = false
    @State private var isExternalPlaybackActive = false
    /// Empêche deux appels concurrents à `load()` (apparition + retour de page)
    /// de créer deux lecteurs pour la même vidéo.
    @State private var isLoadingVideo = false

    // Masquage automatique des contrôles après 2.5 secondes
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?

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
                .onTapGesture {
                    toggleControls()
                }

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
            setupAudioSession()
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
    }

    // MARK: - Gestion de l'affichage des contrôles

    private func scheduleControlsAutoHide(delay: Double = 2.5) {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if !isScrubbing {
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
                AirPlayButton()
                    .frame(width: 32, height: 32)
                tagMenu
                favoriteButton
                Spacer()
            }
            Text(file.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black.opacity(0.25), in: Capsule())
                .padding(.horizontal, 120)
                .frame(maxWidth: .infinity)
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
            Text("Préparation de la lecture…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(20)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Barre du bas (transport, hors zone vidéo)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            playButton

            Text(timeText(currentTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            Slider(value: scrubBinding, in: 0...max(duration, 1)) { editing in
                isScrubbing = editing
                if editing {
                    hideControlsTask?.cancel()
                } else {
                    seek(to: scrubValue, precise: true)
                    scheduleControlsAutoHide(delay: 2.5)
                }
            }
            .tint(.white)
            .controlSize(.large)
            .onChange(of: scrubValue) { _, newValue in
                if isScrubbing { seek(to: newValue) }
            }

            Text(timeText(duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            speedMenu
        }
        .padding(.horizontal, 0)
        .padding(.top, 2)
        .padding(.bottom, -4)
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

    /// Menu des catégories (tags) du drive : coche celles appliquées à la vidéo.
    private var tagMenu: some View {
        Menu {
            ForEach(categories) { category in
                Button {
                    Task { await toggleCategory(category) }
                } label: {
                    HStack {
                        Circle()
                            .fill(Color(hex: category.color) ?? .gray)
                            .frame(width: 10, height: 10)
                        Text(category.name)
                        Spacer()
                        if appliedCategoryIds.contains(category.id) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "tag")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .disabled(categories.isEmpty)
        .accessibilityLabel("Appliquer un tag")
    }

    // MARK: - Transport

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubValue : currentTime },
            set: { scrubValue = $0 }
        )
    }

    private func togglePlay() {
        guard let player else { return }
        scheduleControlsAutoHide(delay: 2.5)
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Reprise après la fin : retour au début.
            if duration > 0, abs(currentTime - duration) < 0.5 {
                player.seek(to: .zero)
            }
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    private func seek(to seconds: Double, precise: Bool = false) {
        guard let player else { return }
        let tolerance: CMTime = precise ? .zero : .indefinite
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = seconds
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
        let newValue = !isFavorite
        isFavorite = newValue
        do {
            try await service.setFavorite(driveId: driveId, fileId: file.id, favorite: newValue)
        } catch {
            isFavorite = !newValue
            errorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func toggleCategory(_ category: Category) async {
        let isApplying = !appliedCategoryIds.contains(category.id)
        if isApplying {
            appliedCategoryIds.insert(category.id)
        } else {
            appliedCategoryIds.remove(category.id)
        }
        do {
            if isApplying {
                try await service.addCategory(driveId: driveId, fileId: file.id, categoryId: category.id)
            } else {
                try await service.removeCategory(driveId: driveId, fileId: file.id, categoryId: category.id)
            }
        } catch {
            if isApplying {
                appliedCategoryIds.remove(category.id)
            } else {
                appliedCategoryIds.insert(category.id)
            }
            errorMessage = "Impossible de modifier le tag : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
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
        guard !isLoadingVideo else { return }
        isLoadingVideo = true
        defer { isLoadingVideo = false }

        async let posterTask: UIImage? = ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, pixels: 400)
        async let categoriesTask: [Category]? = try? service.categories(driveId: driveId)

        // La ressource authentifiée peut déjà avoir été préparée juste avant
        // le tap. Le poster et les tags ne retardent jamais le lecteur.
        guard let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id),
              !isDisappeared,
              !Task.isCancelled
        else {
            errorMessage = "Impossible de préparer cette vidéo. Vérifiez votre connexion puis réessayez."
            return
        }

        startPlayback(asset: asset)

        let (loadedPoster, loadedCategories) = await (posterTask, categoriesTask)
        guard !isDisappeared, !Task.isCancelled else { return }
        if let loadedPoster {
            poster = loadedPoster
        }
        if let loadedCategories, !loadedCategories.isEmpty {
            categories = loadedCategories
        }
    }

    private func startPlayback(asset: AVURLAsset) {
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.isMuted = isMuted
        newPlayer.defaultRate = playbackRate
        newPlayer.allowsExternalPlayback = true
        newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true

        guard !isDisappeared, !Task.isCancelled else {
            newPlayer.pause()
            return
        }
        player = newPlayer
        addObservers(to: newPlayer)
        currentTime = 0
        scrubValue = 0
        newPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        newPlayer.playImmediately(atRate: playbackRate)
        isPlaying = true

        itemStatusObserver = newPlayer.currentItem?.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                await self.retryPlaybackAfterProcessingDelay(
                    lastError: item.error?.localizedDescription ?? "la vidéo n’est pas disponible"
                )
            }
        }
    }

    /// Après un upload, le fichier peut être listé avant d'être servi par le
    /// endpoint de téléchargement. Deux nouvelles tentatives suffisent à
    /// absorber ce court délai sans demander une action manuelle.
    private func retryPlaybackAfterProcessingDelay(lastError: String) async {
        guard !isDisappeared, isActive else { return }
        guard playbackRetryCount < 2 else {
            isPlaying = false
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
        guard !isDisappeared, isActive,
              let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id)
        else { return }
        startPlayback(asset: asset)
    }

    private func addObservers(to player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            if itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
            if !isScrubbing {
                currentTime = time.seconds
            }
            isPlaying = player.timeControlStatus == .playing
            isExternalPlaybackActive = player.isExternalPlaybackActive
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
        }
    }

    private func teardown() {
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }

    // MARK: - Format

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
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
