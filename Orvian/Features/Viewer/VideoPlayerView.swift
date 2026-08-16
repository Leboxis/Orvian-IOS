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

    private let service = KDriveService()

    init(file: DriveFile, driveId: Int) {
        self.file = file
        self.driveId = driveId
        _isFavorite = State(initialValue: file.isFavorite ?? false)
        _appliedCategoryIds = State(initialValue: Set((file.categories ?? []).compactMap { $0.category?.id }))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                videoArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
        }
        .onAppear(perform: setupAudioSession)
        .task {
            await load()
        }
        .onDisappear {
            teardown()
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Barre du haut (hors zone vidéo)

    private var topBar: some View {
        ZStack {
            HStack(spacing: 12) {
                AirPlayButton()
                    .frame(width: 30, height: 30)
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
            HStack(spacing: 12) {
                Spacer()
                muteButton
                closeButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
            if player == nil {
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
        HStack(spacing: 8) {
            playButton

            Text(timeText(currentTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            Slider(value: scrubBinding, in: 0...max(duration, 1)) { editing in
                isScrubbing = editing
                if !editing {
                    seek(to: scrubValue)
                }
            }
            .tint(.white)
            .controlSize(.large)

            Text(timeText(duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            speedMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Fermer")
    }

    /// Vitesse de lecture : petite pastille en bas à droite.
    private var speedMenu: some View {
        Menu {
            ForEach(SpeedOption.allCases) { option in
                Button {
                    setPlaybackRate(option.rate)
                } label: {
                    HStack {
                        Text(option.title)
                        Spacer()
                        if option.rate == playbackRate {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(SpeedOption(rawValue: playbackRate)?.title ?? "1x")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
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
        if isPlaying {
            player.pause()
        } else {
            // Reprise après la fin : retour au début.
            if duration > 0, abs(currentTime - duration) < 0.5 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player?.defaultRate = rate
        if player?.timeControlStatus == .playing {
            player?.rate = rate
        }
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
        async let posterTask: UIImage? = ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, pixels: 400)
        async let urlTask: URL? = MediaURLCache.shared.url(driveId: driveId, fileId: file.id)
        async let categoriesTask: [Category]? = try? service.categories(driveId: driveId)

        let (loadedPoster, url, loadedCategories) = await (posterTask, urlTask, categoriesTask)
        if let loadedPoster {
            withAnimation { poster = loadedPoster }
        }
        if let loadedCategories, !loadedCategories.isEmpty {
            categories = loadedCategories
        }
        guard let url, !Task.isCancelled else { return }

        let newPlayer = AVPlayer(url: url)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.isMuted = isMuted
        newPlayer.defaultRate = playbackRate

        guard !Task.isCancelled else {
            newPlayer.pause()
            return
        }
        player = newPlayer
        addObservers(to: newPlayer)
        newPlayer.play()
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
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player?.pause()
    }

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
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
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}