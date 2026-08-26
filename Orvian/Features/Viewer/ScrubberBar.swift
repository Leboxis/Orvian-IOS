import SwiftUI

/// Barre de progression vidéo façon système : piste épaissie pendant le
/// geste, plage tampon grisée, pouce agrandi et aperçu miniature flottant
/// au-dessus de la position visée.
///
/// Remplace le `Slider` SwiftUI, trop rigide pour ces états : le parent
/// reçoit trois rappels (début / déplacement / fin) et reste maître des
/// seeks, du son et de l'aperçu.
struct ScrubberBar: View {
    /// Position affichée (temps de lecture ou position du doigt).
    let position: Double
    let duration: Double
    /// Fin de la plage bufferisée (secondes depuis le début).
    let bufferedEnd: Double
    let isScrubbing: Bool
    let preview: UIImage?
    let timeFormatter: (Double) -> String
    let onDragStarted: () -> Void
    let onDragChanged: (Double) -> Void
    let onDragEnded: (Double) -> Void

    @State private var isGestureActive = false

    private let bubbleWidth: CGFloat = 150
    private let bubbleImageHeight: CGFloat = 84

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let safeDuration = duration.isFinite && duration > 0 ? duration : 0
            ZStack(alignment: .topLeading) {
                track(width: width)
                    .frame(maxHeight: .infinity)
                    .frame(width: width, alignment: .leading)

                if isScrubbing, let preview {
                    previewBubble(preview, safeDuration: safeDuration, trackWidth: width)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
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

    /// Bulle d'aperçu : frame à la position visée + temps, au-dessus du pouce.
    @ViewBuilder
    private func previewBubble(_ image: UIImage, safeDuration: Double, trackWidth: CGFloat) -> some View {
        let thumbX = clampedRatio(position, duration: safeDuration) * trackWidth
        let bubbleX = min(
            max(thumbX - bubbleWidth / 2, 6),
            max(trackWidth - bubbleWidth - 6, 6)
        )
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: bubbleWidth - 16, height: bubbleImageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(timeFormatter(position))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .frame(width: bubbleWidth, alignment: .center)
        .offset(x: bubbleX, y: -(bubbleImageHeight + 62))
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
