import SwiftUI
import AVFoundation

/// Lecteur vidéo natif : AVPlayer + contrôles sur mesure.
struct VideoPlayerView: View {
    let file: DriveFile
    let driveId: Int

    @Environment(\.dismiss) private var dismiss
    @StateObject private var tracker = PlayerTimeTracker()

    @State private var player: AVPlayer?
    @State private var poster: UIImage?
    @State private var isPlaying = false
    @State private var rate: Float = 1
    @State private var controlsVisible = true
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .onTapGesture { toggleControls() }
            } else if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }

            if player == nil {
                preparing
            }

            if controlsVisible {
                controls
            }
        }
        .onAppear(perform: setupAudioSession)
        .task {
            await load()
        }
        .onDisappear {
            player?.pause()
        }
    }

    // MARK: - Zones

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

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            if player != nil {
                bottomBar
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
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

            Text(file.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.25), in: Capsule())

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 26) {
                controlButton("gobackward.10") {
                    seek(by: -10)
                }
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Lecture")
                controlButton("goforward.10") {
                    seek(by: 10)
                }
            }

            HStack(spacing: 12) {
                Text(timeString(tracker.currentTime))
                    .monospacedDigit()

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : tracker.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(tracker.duration, 0.1)
                ) { editing in
                    isScrubbing = editing
                    if !editing {
                        seek(to: scrubValue)
                    }
                }
                .tint(.white)

                Text(timeString(tracker.duration))
                    .monospacedDigit()

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button {
                            setRate(value)
                        } label: {
                            if value == rate {
                                Label(speedLabel(value), systemImage: "checkmark")
                            } else {
                                Text(speedLabel(value))
                            }
                        }
                    }
                } label: {
                    Text(speedLabel(rate))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .padding(.top, 14)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.black.opacity(0.25), in: Circle())
        }
    }

    // MARK: - Chargement

    private func load() async {
        async let posterTask: UIImage? = ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, pixels: 400)
        async let urlTask: URL? = MediaURLCache.shared.url(driveId: driveId, fileId: file.id)

        let (loadedPoster, url) = await (posterTask, urlTask)
        if let loadedPoster {
            withAnimation { poster = loadedPoster }
        }
        guard let url, !Task.isCancelled else { return }

        let newPlayer = AVPlayer(url: url)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        tracker.attach(to: newPlayer)

        guard !Task.isCancelled else {
            newPlayer.pause()
            tracker.detach()
            return
        }
        player = newPlayer
        play()
    }

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    // MARK: - Lecture

    private func togglePlay() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            play()
        }
        scheduleAutoHide()
    }

    private func play() {
        guard let player else { return }
        player.rate = rate
        isPlaying = true
        scheduleAutoHide()
    }

    private func setRate(_ value: Float) {
        rate = value
        if isPlaying {
            player?.rate = value
        }
        scheduleAutoHide()
    }

    private func seek(by delta: Double) {
        seek(to: tracker.currentTime + delta)
    }

    private func seek(to time: Double) {
        guard let player else { return }
        let clamped = min(max(0, time), max(0, tracker.duration))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .positive,
            toleranceAfter: .positive
        )
        tracker.currentTime = clamped
        scheduleAutoHide()
    }

    // MARK: - Contrôles auto-hide

    private func toggleControls() {
        withAnimation { controlsVisible.toggle() }
        if controlsVisible {
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }
}

/// Suit la position et la durée du lecteur (la vue est une struct : l'observateur
/// vit donc dans cette petite classe).
final class PlayerTimeTracker: NSObject, ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var timeObserverToken: Any?
    private weak var player: AVPlayer?
    private var endObserver: NSKeyValueObservation?

    func attach(to player: AVPlayer) {
        detach()
        self.player = player

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            if itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }
        }

        endObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if player.timeControlStatus == .playing, self.currentTime >= max(0.1, self.duration) {
                    self.currentTime = self.duration
                }
            }
        }
    }

    func detach() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        endObserver = nil
        player = nil
    }

    deinit {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
    }
}

/// Couche AVPlayerLayer dans une UIView.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

private func speedLabel(_ value: Float) -> String {
    value == value.rounded() ? String(format: "%.0f×", value) : String(format: "%.2f×", value)
}
