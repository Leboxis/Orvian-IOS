import SwiftUI
import AVKit

/// Lecteur vidéo natif iOS : VideoPlayer (wrapper SwiftUI d'AVPlayerViewController).
/// Contrôles système (lecture, scrub, vitesse, AirPlay, PiP) — pas de couche maison.
struct VideoPlayerView: View {
    let file: DriveFile
    let driveId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }

            if player == nil {
                preparing
            }

            topBar
        }
        .onAppear(perform: setupAudioSession)
        .task {
            await load()
        }
        .onDisappear {
            // Ne pas couper la lecture si le PiP est actif.
            guard !AVPictureInPictureController.isPictureInPictureActive else { return }
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

    private var topBar: some View {
        VStack {
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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

        guard !Task.isCancelled else {
            newPlayer.pause()
            return
        }
        player = newPlayer
        newPlayer.play()
    }

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }
}