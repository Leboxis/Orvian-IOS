import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Éléments autonomes du lecteur vidéo, extraits de `VideoPlayerView` :
/// options de vitesse, sens du saut, vues UIKit embarquées et gardien de
/// session audio. Aucun n'accède à l'état SwiftUI du lecteur.

/// Sens du saut déclenché par le double-tap (pilote la pastille de rebond).
enum SkipDirection {
    case forward
    case backward
}

/// Vitesses de lecture proposées par la pastille en bas à droite.
enum SpeedOption: Float, CaseIterable, Identifiable {
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
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.configure(player: player)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {}

    final class PlayerLayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        /// `layerClass` impose un `AVPlayerLayer` : le transtypage conditionnel
        /// remplace l'ancien `as!`, qui aurait fait planter l'app si la
        /// garantie venait à être rompue.
        func configure(player: AVPlayer) {
            guard let playerLayer = layer as? AVPlayerLayer else { return }
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
        }
    }
}

/// Bouton AirPlay natif (AVRoutePickerView), teinté en blanc.
struct AirPlayButton: UIViewRepresentable {
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
final class AudioSessionKeeper {
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
