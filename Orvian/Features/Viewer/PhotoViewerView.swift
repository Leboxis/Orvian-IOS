import SwiftUI

/// Visionneuse plein écran : pager, zoom, double-tap, fermeture au swipe.
struct PhotoViewerView: View {
    let context: PhotoViewerContext

    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex: Int

    init(context: PhotoViewerContext) {
        self.context = context
        _pageIndex = State(initialValue: context.startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $pageIndex) {
                ForEach(Array(context.files.enumerated()), id: \.element.id) { index, file in
                    ZoomablePhotoPage(file: file, driveId: context.driveId) {
                        dismiss()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            overlay
        }
        .statusBarHidden(false)
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var overlay: some View {
        VStack {
            HStack(spacing: 12) {
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

                if context.files.indices.contains(pageIndex) {
                    VStack(spacing: 1) {
                        Text(context.files[pageIndex].name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(pageIndex + 1) / \(context.files.count)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                } else {
                    Spacer()
                }

                Color.clear.frame(width: 35, height: 35)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            Spacer()
        }
    }
}

/// Une page photo : miniature instantanée → bascule haute résolution,
/// pinch zoom, double-tap, pan, swipe vertical pour fermer.
private struct ZoomablePhotoPage: View {
    let file: DriveFile
    let driveId: Int
    let onClose: () -> Void

    @State private var hires: UIImage?
    @State private var thumbnail: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                image
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(scale)
                    .offset(panOffset)
                    .opacity(1 - dismissProgress)
                    .gesture(magnifyGesture(in: proxy.size))
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy(duration: 0.3)) {
                            if isZoomed {
                                scale = 1
                                offset = .zero
                                lastScale = 1
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
                    .simultaneousGesture(dragGesture(in: proxy.size))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .task(id: file.id) {
            await loadImages()
        }
    }

    // MARK: - Image

    @ViewBuilder
    private var image: some View {
        if let display {
            Image(uiImage: display)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
        }
    }

    private var display: UIImage? { hires ?? thumbnail }

    private var panOffset: CGSize {
        CGSize(
            width: offset.width + dragOffset.width,
            height: offset.height + (isZoomed ? dragOffset.height : dragOffset.height * 0.55)
        )
    }

    private var dismissProgress: CGFloat {
        guard !isZoomed else { return 0 }
        return min(0.55, abs(dragOffset.height) / 700)
    }

    private func clampOffset(_ raw: CGSize, screenSize: CGSize, currentScale: CGFloat) -> CGSize {
        guard currentScale > 1 else { return .zero }
        let maxOffsetX = max(0, screenSize.width * (currentScale - 1) / 2)
        let maxOffsetY = max(0, screenSize.height * (currentScale - 1) / 2)
        return CGSize(
            width: min(maxOffsetX, max(-maxOffsetX, raw.width)),
            height: min(maxOffsetY, max(-maxOffsetY, raw.height))
        )
    }

    // MARK: - Gestures

    private func magnifyGesture(in screenSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(6, max(1, lastScale * value.magnification))
            }
            .onEnded { _ in
                if scale < 1.15 {
                    withAnimation(.snappy(duration: 0.28)) {
                        scale = 1
                        offset = .zero
                    }
                } else {
                    let clamped = clampOffset(offset, screenSize: screenSize, currentScale: scale)
                    withAnimation(.snappy(duration: 0.2)) {
                        offset = clamped
                    }
                }
                lastScale = scale
            }
    }

    private func dragGesture(in screenSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isZoomed {
                    dragOffset = value.translation
                } else if abs(value.translation.height) > abs(value.translation.width) {
                    // swipe vertical uniquement : le pager garde l'horizontal
                    dragOffset = CGSize(width: 0, height: value.translation.height)
                }
            }
            .onEnded { value in
                if isZoomed {
                    let newRaw = CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    )
                    let clamped = clampOffset(newRaw, screenSize: screenSize, currentScale: scale)
                    withAnimation(.snappy(duration: 0.2)) {
                        offset = clamped
                        dragOffset = .zero
                    }
                } else if abs(value.translation.height) > 130 {
                    onClose()
                } else {
                    withAnimation(.snappy(duration: 0.25)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    // MARK: - Chargement

    private func loadImages() async {
        // Miniature d'abord (instantanée, déjà en cache généralement).
        if let thumb = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, pixels: 400),
           !Task.isCancelled, hires == nil {
            thumbnail = thumb
        }
        // Puis la haute résolution en arrière-plan.
        if let full = await HiresImageStore.shared.image(driveId: driveId, fileId: file.id),
           !Task.isCancelled {
            withAnimation(.easeIn(duration: 0.2)) {
                hires = full
            }
        }
    }
}
