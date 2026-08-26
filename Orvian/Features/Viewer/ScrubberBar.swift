import SwiftUI

/// Barre de progression vidéo façon système : piste épaissie pendant le
/// geste, plage tampon grisée et pouce agrandi.
///
/// Remplace le `Slider` SwiftUI, trop rigide pour ces états : le parent
/// reçoit trois rappels (début / déplacement / fin) et reste maître des
/// seeks et du son.
struct ScrubberBar: View {
    /// Position affichée (temps de lecture ou position du doigt).
    let position: Double
    let duration: Double
    /// Fin de la plage bufferisée (secondes depuis le début).
    let bufferedEnd: Double
    let isScrubbing: Bool
    let timeFormatter: (Double) -> String
    let onDragStarted: () -> Void
    let onDragChanged: (Double) -> Void
    let onDragEnded: (Double) -> Void

    @State private var isGestureActive = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let safeDuration = duration.isFinite && duration > 0 ? duration : 0
            track(width: width)
                .frame(maxHeight: .infinity)
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width, duration: safeDuration))
        }
        .frame(height: 46)
        .animation(.snappy(duration: 0.18), value: isScrubbing)
    }

    // MARK: - Piste

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let barHeight: CGFloat = isScrubbing ? 14 : 7
        let thumbSize: CGFloat = isScrubbing ? 22 : 13
        let positionRatio = clampedRatio(position, duration: duration)
        let bufferedRatio = clampedRatio(bufferedEnd, duration: duration)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: width, height: barHeight)
            Capsule()
                .fill(.white.opacity(0.42))
                .frame(width: max(width * bufferedRatio, barHeight), height: barHeight)
            Capsule()
                .fill(.white)
                .frame(width: max(width * positionRatio, barHeight), height: barHeight)
            Circle()
                .fill(.white)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .offset(x: min(max(width * positionRatio - thumbSize / 2, 0), max(width - thumbSize, 0)))
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Geste

    private func dragGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !isGestureActive {
                    isGestureActive = true
                    onDragStarted()
                }
                onDragChanged(valueFrom(x: value.location.x, width: width, duration: duration))
            }
            .onEnded { value in
                guard isGestureActive else { return }
                isGestureActive = false
                onDragEnded(valueFrom(x: value.location.x, width: width, duration: duration))
            }
    }

    private func valueFrom(x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0 else { return 0 }
        let ratio = min(max(x / width, 0), 1)
        return ratio * duration
    }

    private func clampedRatio(_ seconds: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }
}
