import SwiftUI
import UIKit

struct AnimatedGIFView: UIViewRepresentable {
    let image: GIFImage
    let isPlaying: Bool

    func makeUIView(context: Context) -> GIFPlaybackView {
        let view = GIFPlaybackView()
        view.isUserInteractionEnabled = false
        view.layer.contentsGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: GIFPlaybackView, context: Context) {
        view.configure(image: image, isPlaying: isPlaying)
    }

    static func dismantleUIView(_ view: GIFPlaybackView, coordinator: ()) {
        view.stop()
        view.layer.contents = nil
    }
}

/// Première frame + frame affichée + une frame d'avance : la mémoire ne croît
/// plus avec la durée du GIF, et aucune réduction de résolution n'est nécessaire.
final class GIFPlaybackView: UIView {
    private var playback: Task<Void, Never>?
    private var imageID: UUID?
    private var playing = false

    func stop() {
        playback?.cancel()
        playback = nil
        playing = false
    }

    func configure(image: GIFImage, isPlaying: Bool) {
        guard imageID != image.id || playing != isPlaying else { return }
        stop()
        imageID = image.id
        playing = isPlaying
        layer.contents = image.firstFrame.image
        guard isPlaying, image.frameCount > 1 else { return }
        playback = Task { [weak self] in
            let clock = ContinuousClock()
            var frame = image.firstFrame
            var index = 0
            var completedLoops = 0
            while !Task.isCancelled {
                let deadline = clock.now.advanced(by: .seconds(frame.delay))
                self?.layer.contents = frame.image
                let nextIndex = (index + 1) % image.frameCount
                if nextIndex == 0 {
                    completedLoops += 1
                    if image.loopCount > 0 && completedLoops >= image.loopCount { return }
                }
                // Décoder la suivante pendant l'affichage de la frame courante.
                let next: GIFFrame?
                if nextIndex == 0 {
                    next = image.firstFrame
                } else {
                    next = await image.source.frame(at: nextIndex)
                }
                guard !Task.isCancelled, let next else { return }
                do { try await clock.sleep(until: deadline) } catch { return }
                guard !Task.isCancelled else { return }
                frame = next
                index = nextIndex
            }
        }
    }

    deinit { playback?.cancel() }
}
