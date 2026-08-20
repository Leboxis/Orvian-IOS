import SwiftUI

/// Visionneuse plein écran de médias : pager horizontal sur les images et
/// vidéos voisines. L'ordre et la composition de la liste respectent le tri et
/// les filtres de la grille d'origine (média, orientation, recherche, tri par
/// durée), et la pagination continue depuis le curseur de cette grille.
struct MediaPagerView: View {
    let context: MediaViewerContext

    @Environment(\.dismiss) private var dismiss
    /// Média affiché : identifié par son ID (et non par un index) pour rester
    /// stable quand la liste se réordonne ou s'allonge pendant la pagination.
    @State private var selectedFileID: Int
    /// Médias affichés : instantané de la grille, complété par les pages
    /// suivantes chargées depuis la vue-modèle d'origine.
    @State private var files: [DriveFile]

    init(context: MediaViewerContext) {
        self.context = context
        let firstID = context.files.indices.contains(context.startIndex)
            ? context.files[context.startIndex].id
            : context.files.first?.id ?? 0
        _selectedFileID = State(initialValue: firstID)
        _files = State(initialValue: context.files)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedFileID) {
                ForEach(files) { file in
                    MediaPagerPage(
                        file: file,
                        driveId: context.driveId,
                        isActive: selectedFileID == file.id,
                        onClose: { dismiss() }
                    )
                    .tag(file.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            overlay
        }
        .statusBarHidden(false)
        .persistentSystemOverlays(.hidden)
        .onChange(of: selectedFileID) { _, newID in
            guard let index = files.firstIndex(where: { $0.id == newID }) else { return }
            // Consigne la consultation pour les « médias les plus consultés ».
            MediaUsageStore.recordView(driveId: context.driveId, file: files[index])
            // Proche de la fin de la liste : demande la page suivante à la
            // vue-modèle de la grille, qui reprend là où elle s'était arrêtée.
            if let viewModel = context.viewModel, index >= files.count - 2 {
                Task { await viewModel.loadMoreIfNeeded() }
            }
        }
        .onChange(of: context.viewModel?.items) { _, _ in
            refreshFiles()
        }
    }

    /// Reconstruit la liste des médias après un chargement de page : réapplique
    /// les mêmes filtres/tri que la grille d'origine, puis conserve la position.
    private func refreshFiles() {
        guard let viewModel = context.viewModel else { return }
        let visible = context.filters.visible(
            viewModel.items,
            searchText: context.searchText,
            mediaMetadata: MediaMetadataStore.shared
        )
        let media = visible.filter { $0.isImage || $0.isVideo }
        guard media.map(\.id) != files.map(\.id) else { return }
        files = media
        if !files.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = files.first?.id ?? 0
        }
    }

    private var currentFile: DriveFile? {
        files.first { $0.id == selectedFileID }
    }

    @ViewBuilder
    private var overlay: some View {
        VStack {
            // Les vidéos possèdent leur propre barre (titre, favori, tags,
            // transport, fermer) : on n'ajoute rien au-dessus. Les images, en
            // revanche, n'ont aucun chrome propre : la barre du pager les sert.
            if let currentFile, currentFile.isImage {
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

                    VStack(spacing: 1) {
                        Text(currentFile.name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let index = files.firstIndex(where: { $0.id == selectedFileID }) {
                            Text("\(index + 1) / \(files.count)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)

                    Color.clear.frame(width: 35, height: 35)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            Spacer()
        }
    }
}

/// Une page du pager : image (miniature → haute résolution, zoom, fermeture au
/// swipe vertical) ou vidéo (lecteur personnalisé qui ne lit que lorsqu'elle
/// est l'élément courant du pager).
private struct MediaPagerPage: View {
    let file: DriveFile
    let driveId: Int
    let isActive: Bool
    let onClose: () -> Void

    var body: some View {
        Group {
            if file.isImage {
                ZoomablePhotoPage(file: file, driveId: driveId, onClose: onClose)
            } else if file.isVideo {
                VideoPlayerView(file: file, driveId: driveId, isActive: isActive)
            } else {
                // Défensif : le pager ne contient que des images et des vidéos.
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(file.name)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
            .gesture(magnifyGesture(in: proxy.size))
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
                let newScale = min(6, max(1, lastScale * value.magnification))
                // Ancre le zoom sur le milieu des deux doigts : le point situé
                // sous l'ancre de départ reste fixe pendant tout le geste.
                let previousScale = scale
                let ratio = previousScale > 0 ? newScale / previousScale : 1
                let anchor = value.startLocation
                let d = CGPoint(
                    x: anchor.x - screenSize.width / 2,
                    y: anchor.y - screenSize.height / 2
                )
                offset = CGSize(
                    width: d.x * (1 - ratio) + offset.width * ratio,
                    height: d.y * (1 - ratio) + offset.height * ratio
                )
                scale = newScale
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

    /// Miniature (placeholder instantané) et haute résolution téléchargées en
    /// parallèle : la pleine qualité démarre dès l'ouverture, sans attendre la
    /// miniature, et s'affiche dès qu'elle est prête.
    private func loadImages() async {
        async let thumbnailTask = ThumbnailProvider.shared.thumbnail(
            driveId: driveId,
            fileId: file.id,
            pixels: 400
        )
        async let hiresTask = HiresImageStore.shared.image(driveId: driveId, fileId: file.id)
        if let thumb = await thumbnailTask, !Task.isCancelled, hires == nil {
            thumbnail = thumb
        }
        if let full = await hiresTask, !Task.isCancelled {
            withAnimation(.easeIn(duration: 0.2)) {
                hires = full
            }
        }
    }
}