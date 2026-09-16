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
    let onDragCancelled: () -> Void

    @State private var isGestureActive = false
    @GestureState private var isDragging = false

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position de lecture")
        .accessibilityValue(duration.isFinite && duration > 0
            ? "\(timeFormatter(position.isFinite ? max(0, position) : 0)) sur \(timeFormatter(duration))"
            : "Durée indisponible")
        .accessibilityHint("Balayez vers le haut ou le bas pour avancer ou reculer de dix secondes")
        .accessibilityAdjustableAction { direction in
            guard duration.isFinite, duration > 0 else { return }
            let delta: Double
            switch direction {
            case .increment: delta = 10
            case .decrement: delta = -10
            @unknown default: return
            }
            let target = min(duration, max(0, (position.isFinite ? position : 0) + delta))
            onDragStarted()
            onDragChanged(target)
            onDragEnded(target)
        }
        .animation(.snappy(duration: 0.18), value: isScrubbing)
        .onChange(of: isDragging) { _, dragging in
            // GestureState se réinitialise aussi si le système annule le geste,
            // alors que onEnded n'est appelé qu'en cas de fin normale.
            if !dragging, isGestureActive {
                isGestureActive = false
                onDragCancelled()
            }
        }
        .onDisappear {
            if isGestureActive {
                isGestureActive = false
                onDragCancelled()
            }
        }
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
                // Pas d'ombre : elle force une passe de rendu hors écran à chaque
                // frame (4x/s en lecture, 60 Hz en drag) pour un pouce déjà
                // contrasté sur fond sombre. L'anneau fin garde le relief.
                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
                .frame(width: thumbSize, height: thumbSize)
                .offset(x: min(max(width * positionRatio - thumbSize / 2, 0), max(width - thumbSize, 0)))
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Geste

    private func dragGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isDragging) { _, dragging, _ in dragging = true }
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
