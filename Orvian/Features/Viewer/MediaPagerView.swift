import SwiftUI
import UIKit

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
    /// Déplacement vertical du pager lors d'un geste de fermeture sur une image.
    @State private var dismissOffset: CGFloat = 0
    /// Les pages conservent leur zoom quand elles restent en mémoire. Cet
    /// ensemble permet au pager de ne jamais interpréter leur pan comme une
    /// demande de fermeture.
    @State private var zoomedImageIDs: Set<Int> = []

    // Barre du haut (images uniquement) : favori et tags, même chrome que le
    // lecteur vidéo. Les états sont tenus par fichier afin de survivre aux
    // allers-retours entre les pages du pager.
    @State private var favoriteByFileID: [Int: Bool] = [:]
    @State private var favoriteMutationsInFlight: Set<Int> = []
    @State private var appliedCategoryIdsByFileID: [Int: Set<Int>] = [:]
    @State private var tagSheetFile: DriveFile?
    @State private var favoriteErrorMessage: String?

    // Copie du titre : pastille « Copié » brève après le tap.
    @State private var titleCopied = false
    @State private var titleCopyResetTask: Task<Void, Never>?

    private let service = KDriveService()

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
                        hiresRequested: hiresPreloadIDs.contains(file.id),
                        onImageZoomChanged: { isZoomed in
                            setImageZoomed(isZoomed, fileID: file.id)
                        }
                    )
                    .tag(file.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dismissOffset * 0.55)
            .opacity(1 - min(0.55, abs(dismissOffset) / 700))
            // Le geste vit sur le TabView lui-même : il peut ainsi reconnaître
            // le vertical sans priver son pager interne du swipe horizontal.
            .simultaneousGesture(imageDismissGesture)

            overlay
        }
        .statusBarHidden(false)
        .persistentSystemOverlays(.hidden)
        .task {
            // `onChange` ne s'exécute pas à l'ouverture. Sans ce chargement,
            // ouvrir directement le dernier média rendait le swipe suivant
            // impossible alors que le serveur possédait encore des pages.
            await loadMoreMediaIfNeeded(around: selectedFileID)
        }
        .onChange(of: selectedFileID) { _, newID in
            dismissOffset = 0
            guard let index = files.firstIndex(where: { $0.id == newID }) else { return }
            // Proche de la fin de la liste : demande la page suivante à la
            // vue-modèle de la grille, qui reprend là où elle s'était arrêtée.
            if index >= files.count - 2 {
                Task { await loadMoreMediaIfNeeded(around: newID) }
            }
        }
        .onChange(of: context.viewModel?.items) { _, _ in
            refreshFiles()
            // Si la page reçue ne contenait aucun média visible, continuer
            // depuis le même élément au lieu de laisser le pager en impasse.
            Task { await loadMoreMediaIfNeeded(around: selectedFileID) }
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

    /// Charge autant de pages que nécessaire pour obtenir un média suivant.
    /// Une page peut ne contenir que des dossiers ou des fichiers masqués par
    /// les filtres : dans ce cas, on poursuit tant que la pagination progresse.
    private func loadMoreMediaIfNeeded(around fileID: Int) async {
        guard let viewModel = context.viewModel else { return }

        while !Task.isCancelled,
              viewModel.hasMore {
            await resolveVideoMetadataIfNeeded(for: viewModel)
            guard !Task.isCancelled,
                  let index = files.firstIndex(where: { $0.id == fileID }),
                  index >= files.count - 2
            else { return }

            let previousItemCount = viewModel.items.count
            await viewModel.loadMoreIfNeeded()
            guard !Task.isCancelled, viewModel.errorMessage == nil else { return }

            await resolveVideoMetadataIfNeeded(for: viewModel)

            // Protection contre une API qui renverrait la même page sans
            // avancer : évite une boucle réseau infinie dans la visionneuse.
            guard viewModel.items.count > previousItemCount else { return }
        }
    }

    private func resolveVideoMetadataIfNeeded(for viewModel: FileGridViewModel) async {
        guard context.filters.sort == .duration
                || context.filters.orientation != nil
                || context.filters.highResolutionVideosOnly
        else {
            return
        }
        await MediaMetadataStore.shared.resolveAll(driveId: context.driveId, items: viewModel.items)
        refreshFiles()
    }

    private var currentFile: DriveFile? {
        files.first { $0.id == selectedFileID }
    }

    /// Pages dont la haute résolution doit être chargée : la page courante et
    /// la suivante (préchargement N+1). Les autres pages ne déclenchent aucun
    /// téléchargement : ouvrir un album de centaines de médias ne lance plus
    /// qu'un ou deux téléchargements pleine résolution au lieu de tous.
    private var hiresPreloadIDs: Set<Int> {
        guard let selectedIndex = files.firstIndex(where: { $0.id == selectedFileID }) else {
            return []
        }
        var ids = [files[selectedIndex].id]
        if selectedIndex + 1 < files.count {
            ids.append(files[selectedIndex + 1].id)
        }
        return Set(ids)
    }

    private var canDismissCurrentImage: Bool {
        currentFile?.isImage == true && !zoomedImageIDs.contains(selectedFileID)
    }

    private var imageDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard canDismissCurrentImage,
                      abs(value.translation.height) > abs(value.translation.width)
                else {
                    dismissOffset = 0
                    return
                }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                let isVertical = abs(value.translation.height) > abs(value.translation.width)
                if canDismissCurrentImage, isVertical, abs(value.translation.height) > 130 {
                    dismiss()
                } else {
                    withAnimation(.snappy(duration: 0.25)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func setImageZoomed(_ isZoomed: Bool, fileID: Int) {
        if isZoomed {
            zoomedImageIDs.insert(fileID)
        } else {
            zoomedImageIDs.remove(fileID)
        }
    }

    /// Barre du haut des images : favori puis tags à gauche du titre, fermer
    /// à droite — même pastille de titre que le lecteur vidéo. Le tap sur le
    /// titre copie le nom dans le presse-papiers.
    @ViewBuilder
    private var overlay: some View {
        VStack {
            // Les vidéos possèdent leur propre barre (titre, favori, tags,
            // transport, fermer) : on n'ajoute rien au-dessus. Les images, en
            // revanche, n'ont aucun chrome propre : la barre du pager les sert.
            if let currentFile, currentFile.isImage {
                ZStack {
                    HStack(spacing: 8) {
                        favoriteButton(for: currentFile)
                        tagButton(for: currentFile)
                        Spacer()
                    }
                    titleArea(for: currentFile)
                    HStack(spacing: 8) {
                        Spacer()
                        closeButton
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            Spacer()

            if let errorMessage = context.viewModel?.errorMessage {
                Button {
                    Task { await loadMoreMediaIfNeeded(around: selectedFileID) }
                } label: {
                    Label("Réessayer le chargement", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityHint(Text(errorMessage))
                .padding(.bottom, currentFile?.isVideo == true ? 64 : 24)
            }
        }
        .sheet(item: $tagSheetFile) { sheetFile in
            TagsEditorSheet(
                driveId: context.driveId,
                file: sheetFile,
                initialAppliedIds: appliedCategoryIdsByFileID[sheetFile.id]
                    ?? Set((sheetFile.categories ?? []).map(\.categoryId)),
                onChanged: { category, applied in
                    var ids = appliedCategoryIdsByFileID[sheetFile.id]
                        ?? Set((sheetFile.categories ?? []).map(\.categoryId))
                    if applied {
                        ids.insert(category.id)
                    } else {
                        ids.remove(category.id)
                    }
                    appliedCategoryIdsByFileID[sheetFile.id] = ids
                    FileGridMutationCenter.shared.publish(
                        .category(driveId: context.driveId, fileId: sheetFile.id, category: category, applied: applied)
                    )
                }
            )
        }
        .alert("Erreur", isPresented: .init(
            get: { favoriteErrorMessage != nil },
            set: { if !$0 { favoriteErrorMessage = nil } }
        )) {
            Button("OK") { favoriteErrorMessage = nil }
        } message: {
            Text(favoriteErrorMessage ?? "")
        }
    }

    // MARK: - Barre du haut (images)

    /// Titre centré, largeur bornée à 40 % de l'écran (20 % de part et
    /// d'autre du centre) : le tap copie le nom dans le presse-papiers ; la
    /// pastille « Copié » remplace brièvement le titre comme accusé visuel.
    private func titleArea(for file: DriveFile) -> some View {
        VStack(spacing: 1) {
            Group {
                if titleCopied {
                    Label("Copié", systemImage: "doc.on.doc")
                        .font(.body.weight(.medium))
                } else {
                    Text(file.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.black.opacity(0.25), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                UIPasteboard.general.string = file.name
                titleCopied = true
                scheduleTitleCopyReset()
            }
        }
        .padding(.horizontal, UIScreen.main.bounds.width * 0.2)
        .frame(maxWidth: .infinity)
    }

    /// Même pastille « Copié » brève que dans les autres visionneuses : le
    /// drapeau retombe tout seul, sauf si le titre est copié à nouveau avant.
    private func scheduleTitleCopyReset() {
        titleCopyResetTask?.cancel()
        titleCopyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                titleCopied = false
            }
        }
    }

    /// Même éditeur que le lecteur vidéo (feuille partagée, couleurs visibles).
    private func tagButton(for file: DriveFile) -> some View {
        Button {
            tagSheetFile = file
        } label: {
            Image(systemName: "tag")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel("Appliquer un tag")
    }

    /// Étoile pleine jaune si favori, identique au lecteur vidéo ; mise à
    /// jour optimiste avec repli en cas d'échec réseau.
    private func favoriteButton(for file: DriveFile) -> some View {
        Button {
            Task { await toggleFavorite(for: file) }
        } label: {
            Image(systemName: isFavorite(file) ? "star.fill" : "star")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFavorite(file) ? .yellow : .white)
                .frame(width: 30, height: 30)
        }
        .disabled(favoriteMutationsInFlight.contains(file.id))
        .accessibilityLabel(isFavorite(file) ? "Retirer des favoris" : "Ajouter aux favoris")
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

    /// État favori par fichier : la valeur connue du pager fait foi, sinon
    /// repli sur les données de la grille (reprises à chaque `refreshFiles`).
    private func isFavorite(_ file: DriveFile) -> Bool {
        favoriteByFileID[file.id] ?? (file.isFavorite ?? false)
    }

    private func toggleFavorite(for file: DriveFile) async {
        guard !favoriteMutationsInFlight.contains(file.id) else { return }
        favoriteMutationsInFlight.insert(file.id)
        defer { favoriteMutationsInFlight.remove(file.id) }
        let newValue = !isFavorite(file)
        favoriteByFileID[file.id] = newValue
        do {
            try await service.setFavorite(driveId: context.driveId, fileId: file.id, favorite: newValue)
            FileGridMutationCenter.shared.publish(
                .favorite(driveId: context.driveId, fileId: file.id, isFavorite: newValue)
            )
        } catch {
            if favoriteByFileID[file.id] == newValue {
                favoriteByFileID[file.id] = !newValue
            }
            favoriteErrorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}

/// Une page du pager : image (miniature instantanée → haute résolution gated
/// N+1, zoom, fermeture au swipe vertical) ou vidéo (lecteur personnalisé qui
/// ne lit que lorsqu'elle est l'élément courant du pager).
private struct MediaPagerPage: View {
    let file: DriveFile
    let driveId: Int
    let isActive: Bool
    /// Vrai pour la page courante ou la suivante : seule condition de
    /// téléchargement de l'image pleine résolution.
    let hiresRequested: Bool
    let onImageZoomChanged: (Bool) -> Void

    var body: some View {
        Group {
            if file.isImage {
                ZoomablePhotoPage(
                    file: file,
                    driveId: driveId,
                    hiresRequested: hiresRequested,
                    onZoomChanged: onImageZoomChanged
                )
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

/// Une page photo : miniature instantanée → bascule haute résolution gated
/// (page courante ou suivante uniquement), pinch zoom, double-tap, pan,
/// swipe vertical pour fermer.
private struct ZoomablePhotoPage: View {
    let file: DriveFile
    let driveId: Int
    /// Vrai dès que la page est courante ou devenue la page suivante : lance
    /// (ou relance après annulation) le téléchargement pleine résolution.
    let hiresRequested: Bool
    let onZoomChanged: (Bool) -> Void

    @State private var hires: UIImage?
    @State private var thumbnail: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        GeometryReader { proxy in
            // Zone réservée à la barre du pager (tags, titre, favori) : les
            // images plein cadre (16/9 et plus) commencent sous les boutons
            // au lieu de passer derrière eux.
            let clearance = topBarClearance(in: proxy)
            let contentSize = CGSize(
                width: proxy.size.width,
                height: max(0, proxy.size.height - clearance)
            )
            ZStack {
                interactiveImage(in: contentSize)
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .contentShape(Rectangle())
            .gesture(magnifyGesture(in: contentSize))
            .padding(.top, clearance)
        }
        .task(id: file.id) {
            await loadThumbnail()
        }
        .task(id: hiresRequested) {
            guard hiresRequested else { return }
            await loadHiresWithRetry()
        }
        .onAppear {
            onZoomChanged(isZoomed)
        }
        .onChange(of: isZoomed) { _, newValue in
            onZoomChanged(newValue)
        }
        .onDisappear {
            onZoomChanged(false)
        }
    }

    // MARK: - Image

    /// Marge haute réservée à la barre du pager : hauteur de la safe area
    /// (barre d'état) plus la barre elle-même, plafonnée pour ne pas écraser
    /// l'image sur les grands écrans.
    private func topBarClearance(in proxy: GeometryProxy) -> CGFloat {
        let safeTop = proxy.safeAreaInsets.top
        return min(160, safeTop + 56)
    }

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

    /// À l'échelle normale, aucun drag n'est attaché à l'image : le pager
    /// horizontal reçoit donc toute sa surface. Une fois zoomée, l'image prend
    /// la priorité afin qu'un panoramique ne change pas de page.
    @ViewBuilder
    private func interactiveImage(in screenSize: CGSize) -> some View {
        if isZoomed {
            displayedImage(in: screenSize)
                .highPriorityGesture(zoomedPanGesture(in: screenSize))
        } else {
            displayedImage(in: screenSize)
        }
    }

    private func displayedImage(in screenSize: CGSize) -> some View {
        image
            .frame(width: screenSize.width, height: screenSize.height)
            .scaleEffect(scale)
            .offset(panOffset)
            .onTapGesture(count: 2) {
                withAnimation(.snappy(duration: 0.3)) {
                    if isZoomed {
                        scale = 1
                        offset = .zero
                        dragOffset = .zero
                        lastScale = 1
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
    }

    private var panOffset: CGSize {
        CGSize(
            width: offset.width + dragOffset.width,
            height: offset.height + dragOffset.height
        )
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

    private func zoomedPanGesture(in screenSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let newRaw = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
                let clamped = clampOffset(newRaw, screenSize: screenSize, currentScale: scale)
                withAnimation(.snappy(duration: 0.2)) {
                    offset = clamped
                    dragOffset = .zero
                }
            }
    }

    // MARK: - Chargement

    /// Miniature (placeholder instantané) : cache mémoire, disque ou réseau
    /// régulé. Toujours chargée, quel que soit l'état du préchargement HD.
    /// `DS.thumbnailPixels` est la clé canonique : l'API renvoie la même
    /// image quelle que soit la taille demandée, une autre valeur ne ferait
    /// que dupliquer le téléchargement et les caches.
    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        let image = await ThumbnailProvider.shared.thumbnail(
            driveId: driveId,
            fileId: file.id,
            pixels: DS.thumbnailPixels
        )
        guard !Task.isCancelled, thumbnail == nil else { return }
        thumbnail = image
    }

    /// Haute résolution originale avec quelques tentatives espacées : un
    /// échec réseau ponctuel ne laisse plus la page bloquée sur la miniature.
    /// La bascule s'anime même si elle survient longtemps après l'ouverture,
    /// y compris pendant un zoom déjà en cours (`display` bascule vers la
    /// version nette dès qu'elle arrive).
    private func loadHiresWithRetry() async {
        guard hires == nil else { return }
        let retryDelays: [Duration] = [.zero, .seconds(3), .seconds(8)]
        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let image = await HiresImageStore.shared.image(driveId: driveId, fileId: file.id)
            guard !Task.isCancelled else { return }
            if let image {
                withAnimation(.easeIn(duration: 0.2)) {
                    hires = image
                }
                return
            }
        }
    }
}
