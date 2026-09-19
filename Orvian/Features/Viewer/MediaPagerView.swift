import SwiftUI
import UIKit

/// Visionneuse plein écran de médias : pager horizontal sur les images et
/// vidéos voisines. L'ordre et la composition de la liste respectent le tri et
/// les filtres de la grille d'origine (média, orientation, recherche, tri par
/// durée), et la pagination continue depuis le curseur de cette grille.
struct MediaPagerView: View {
    let context: MediaViewerContext

    @Environment(\.dismiss) private var dismiss
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = true
    /// Média affiché : identifié par son ID (et non par un index) pour rester
    /// stable quand la liste se réordonne ou s'allonge pendant la pagination.
    @State private var selectedFileID: Int
    /// Médias affichés : instantané de la grille, complété par les pages
    /// suivantes chargées depuis la vue-modèle d'origine. La liste reste la
    /// source de vérité de la sélection et de la pagination.
    @State private var settled: [DriveFile]
    /// Position de chaque média dans `settled`.
    ///
    /// Le pager cherchait l'index de la sélection (`firstIndex(where:)`), puis
    /// les voisins, **à chaque évaluation de son corps** — donc à chaque frame
    /// du geste de fermeture, qui déplace verticalement tout le pager. La table
    /// est construite une fois par liste (chargement, pagination, filtre) :
    /// chaque lecture devient O(1).
    @State private var indexByFileID: [Int: Int] = [:]
    /// Inclut la résolution des métadonnées, même sans page réseau suivante.
    @State private var mediaLoadsInFlight = 0
    /// Déplacement vertical du pager lors d'un geste de fermeture sur une image.
    @State private var dismissOffset: CGFloat = 0
    /// Les pages conservent leur zoom quand elles restent en mémoire. Cet
    /// ensemble permet au pager de ne jamais interpréter leur pan comme une
    /// demande de fermeture.
    @State private var zoomedImageIDs: Set<Int> = []
    /// Pages vidéo dont une barre de contrôle est actuellement touchée.
    /// Tant que l'ensemble n'est pas vide, le pager horizontal est suspendu.
    @State private var controlInteractionFileIDs: Set<Int> = []

    // Barre du haut (images uniquement) : favori et tags, même chrome que le
    // lecteur vidéo. Les états sont tenus par fichier afin de survivre aux
    // allers-retours entre les pages du pager.
    @State private var favoriteByFileID: [Int: Bool] = [:]
    @State private var favoriteMutationsInFlight: Set<Int> = []
    @State private var appliedCategoryIdsByFileID: [Int: Set<Int>] = [:]
    @State private var tagSheetFile: DriveFile?
    @State private var favoriteErrorMessage: String?

    private let service = KDriveService()

    init(context: MediaViewerContext) {
        self.context = context
        let firstID = context.files.indices.contains(context.startIndex)
            ? context.files[context.startIndex].id
            : context.files.first?.id ?? 0
        _selectedFileID = State(initialValue: firstID)
        _settled = State(initialValue: context.files)
        _indexByFileID = State(initialValue: Self.indexMap(context.files))
    }

    /// Table `fileId → position` dans `settled`.
    private static func indexMap(_ files: [DriveFile]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        map.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            map[file.id] = index
        }
        return map
    }

    /// Position du média affiché, sans balayage de la liste.
    private var selectionIndex: Int? { indexByFileID[selectedFileID] }

    /// Fenêtre de rendu autour de la sélection : le `TabView` garde le même
    /// nombre d'enfants (mêmes `tag`), seul le contenu varie. Les pages
    /// éloignées affichent un placeholder vide au lieu d'instancier lecteur
    /// vidéo / zoom / tâches d'images — 500 médias = 5 vraies pages + 495 vides.
    /// Sans cela, chaque page lourde vit dans le view-graph même à distance.
    private func isPageNear(_ fileID: Int) -> Bool {
        guard let selectedIndex = selectionIndex,
              let index = indexByFileID[fileID] else { return true }
        return abs(index - selectedIndex) <= 2
    }

    var body: some View {
        // Calculé une fois par rendu : évaluée dans le `ForEach`, cette
        // propriété relançait un balayage complet de la liste **par page** —
        // soit O(n²) à chaque frame du geste de fermeture, qui réévalue ce
        // corps à chaque déplacement du doigt.
        let preloadIDs = hiresPreloadIDs
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedFileID) {
                // Le `TabView` en style page supporte mal qu'on ajoute/retire
                // ses enfants pendant la transition (sauts, pages perdues).
                // On garde donc tous les enfants déclarés, mais seules les
                // pages proches de la sélection (±2) instancient leur contenu
                // lourd. Le coût vidéo/HD reste borné par `isActive` et
                // `hiresRequested`, le coût view-graph par `isPageNear`.
                ForEach(settled) { file in
                    Group {
                        if isPageNear(file.id) {
                            MediaPagerPage(
                                file: file,
                                driveId: context.driveId,
                                isActive: selectedFileID == file.id,
                                hiresRequested: preloadIDs.contains(file.id),
                                onImageZoomChanged: { isZoomed in
                                    setImageZoomed(isZoomed, fileID: file.id)
                                },
                                onVideoControlsInteractionChanged: { isInteracting in
                                    setVideoControlsInteracting(isInteracting, fileID: file.id)
                                }
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .tag(file.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(!controlInteractionFileIDs.isEmpty)
            .offset(y: dismissOffset * 0.55)
            .opacity(1 - min(0.55, abs(dismissOffset) / 700))
            // Le geste vit sur le TabView lui-même : il peut ainsi reconnaître
            // le vertical sans priver son pager interne du swipe horizontal.
            .simultaneousGesture(imageDismissGesture)

            if settled.isEmpty {
                if mediaLoadsInFlight > 0 {
                    ProgressView("Chargement des médias…")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else if hasUnresolvedFilteredMedia {
                    ContentUnavailableView {
                        Label("Médias indisponibles", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("Réessayez pour afficher les médias correspondant à cette sélection.")
                    } actions: {
                        Button("Réessayer") {
                            Task { await loadMoreMediaIfNeeded(around: selectedFileID) }
                        }
                    }
                    .environment(\.colorScheme, .dark)
                } else if let errorMessage = context.viewModel?.errorMessage {
                    ContentUnavailableView(
                        "Chargement interrompu",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    .environment(\.colorScheme, .dark)
                } else {
                    ContentUnavailableView(
                        "Aucun média",
                        systemImage: "photo.on.rectangle",
                        description: Text("Aucun média disponible ne correspond à cette sélection.")
                    )
                    .environment(\.colorScheme, .dark)
                }
            }

            overlay
        }
        .statusBarHidden(false)
        .persistentSystemOverlays(.hidden)
        .task(id: context.viewModel?.itemsRevision) {
            // `onChange` ne s'exécute pas à l'ouverture. Sans ce chargement,
            // ouvrir directement le dernier média rendait le swipe suivant
            // impossible alors que le serveur possédait encore des pages.
            refreshFiles()
            await loadMoreMediaIfNeeded(around: selectedFileID)
        }
        .onChange(of: selectedFileID) { _, newID in
            dismissOffset = 0
            controlInteractionFileIDs.removeAll()
            guard let index = settled.firstIndex(where: { $0.id == newID }) else { return }
            // Proche de la fin de la liste : demande la page suivante à la
            // vue-modèle de la grille, qui reprend là où elle s'était arrêtée.
            if index >= settled.count - 2 {
                Task { await loadMoreMediaIfNeeded(around: newID) }
            }
        }
    }

    /// Reconstruit la liste des médias après un chargement de page : réapplique
    /// les mêmes filtres/tri que la grille d'origine, puis conserve la position.
    ///
    /// La passe reste synchrone et sur le MainActor : depuis que les
    /// métadonnées se lisent en O(1) (`VideoMetadataSnapshot`) et que les
    /// recherches par nom sont repliées en cache, elle coûte quelques
    /// millisecondes sur les très grandes listes — et elle garantit, sans
    /// délai ni double écriture d'état, que la liste affichée est toujours la
    /// version la plus récente après un chargement de page. La fonction est
    /// prête à passer hors du MainActor (`FileFilters.visible` est
    /// `nonisolated`) si un profilage le justifie.
    private func refreshFiles() {
        guard let viewModel = context.viewModel else { return }
        let visible = context.filters.visible(
            viewModel.items,
            searchText: context.searchText,
            metadata: MediaMetadataStore.shared.snapshot(driveId: context.driveId, items: viewModel.items)
        )
        let media = visible.filter { $0.isImage || $0.isVideo }
        guard media.map(\.id) != settled.map(\.id) else { return }
        // Une suppression ou un filtre peut réellement vider la liste.
        // Afficher l'attente ou l'état vide avec fermeture, jamais d'anciens
        // fichiers qui ne figurent plus dans la sélection.
        settled = media
        indexByFileID = Self.indexMap(media)
        let ids = Set(media.map(\.id))
        zoomedImageIDs.formIntersection(ids)
        controlInteractionFileIDs.formIntersection(ids)
        if let tagSheetFile, !ids.contains(tagSheetFile.id) { self.tagSheetFile = nil }
        if !settled.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = settled.first?.id ?? 0
        }
    }

    /// Charge autant de pages que nécessaire pour obtenir un média suivant.
    /// Une page peut ne contenir que des dossiers ou des fichiers masqués par
    /// les filtres : dans ce cas, on poursuit tant que la pagination progresse.
    private func loadMoreMediaIfNeeded(around fileID: Int) async {
        guard let viewModel = context.viewModel else { return }
        mediaLoadsInFlight += 1
        defer { mediaLoadsInFlight -= 1 }

        // Les métadonnées manquantes doivent aussi être résolues quand la
        // dernière page réseau a déjà été chargée.
        await resolveVideoMetadataIfNeeded(for: viewModel)
        guard !Task.isCancelled else { return }
        refreshFiles()

        while !Task.isCancelled,
              viewModel.hasMore {
            if !settled.isEmpty {
                guard let index = settled.firstIndex(where: { $0.id == fileID }),
                      index >= settled.count - 2 else { return }
            }

            let previousItemCount = viewModel.items.count
            await viewModel.loadMoreIfNeeded()
            guard !Task.isCancelled, viewModel.errorMessage == nil else { return }

            await resolveVideoMetadataIfNeeded(for: viewModel)
            guard !Task.isCancelled else { return }
            refreshFiles()

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
        guard let index = selectionIndex, settled.indices.contains(index) else { return nil }
        return settled[index]
    }

    /// Après un échec de résolution, une vidéo encore inconnue ne prouve pas
    /// que la sélection est vide. Seuls les filtres indépendants des métadonnées
    /// permettent de décider quels fichiers restent candidats.
    private var hasUnresolvedFilteredMedia: Bool {
        guard let viewModel = context.viewModel,
              context.filters.orientation != nil || context.filters.highResolutionVideosOnly else { return false }
        var filters = context.filters
        filters.orientation = nil
        filters.highResolutionVideosOnly = false
        // Instantané vide : ce diagnostic ne décide que de l'affichage d'un
        // état vide. Y injecter les métadonnées appliquerait aussi le tri par
        // durée, qui dépend justement des analyses en cours ; l'ordre est ici
        // sans importance, seul l'ensemble des candidats compte.
        let candidates = filters.visible(
            viewModel.items,
            searchText: context.searchText,
            metadata: VideoMetadataSnapshot()
        )
        return candidates.contains {
            $0.isVideo && MediaMetadataStore.shared.info(driveId: context.driveId, for: $0.id) == nil
        }
    }

    /// La page courante est toujours chargée. La suivante (préchargement N+1)
    /// respecte la même préférence réseau que la grille ; les autres pages ne
    /// déclenchent aucun téléchargement haute résolution.
    private var hiresPreloadIDs: Set<Int> {
        guard let selectedIndex = selectionIndex else {
            return []
        }
        var ids = [settled[selectedIndex].id]
        let allowsNextPagePrefetch = !prefetchOnWiFiOnly
            || NetworkMonitor.shared.allowsBackgroundPrefetch
        if allowsNextPagePrefetch, selectedIndex + 1 < settled.count {
            ids.append(settled[selectedIndex + 1].id)
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

    private func setVideoControlsInteracting(_ isInteracting: Bool, fileID: Int) {
        if isInteracting {
            controlInteractionFileIDs.insert(fileID)
        } else {
            controlInteractionFileIDs.remove(fileID)
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
                    MediaTitlePill(name: currentFile.name)
                    HStack(spacing: 8) {
                        Spacer()
                        closeButton
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            } else if settled.isEmpty {
                // Aucune page (liste momentanément vide) : la barre ci-dessus
                // n'existerait pas et la fermeture au swipe vertical n'est
                // disponible que sur les images. Sans ce bouton, la visionneuse
                // serait un écran noir sans aucun moyen d'en sortir.
                HStack {
                    Spacer()
                    closeButton
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

    /// Même éditeur que le lecteur vidéo (feuille partagée, couleurs visibles).
    private func tagButton(for file: DriveFile) -> some View {
        MediaTagButton {
            tagSheetFile = file
        }
    }

    /// Étoile pleine jaune si favori, identique au lecteur vidéo ; mise à
    /// jour optimiste avec repli en cas d'échec réseau.
    private func favoriteButton(for file: DriveFile) -> some View {
        MediaFavoriteButton(
            isFavorite: isFavorite(file),
            isDisabled: favoriteMutationsInFlight.contains(file.id)
        ) {
            Task { await toggleFavorite(for: file) }
        }
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
    let onVideoControlsInteractionChanged: (Bool) -> Void

    var body: some View {
        Group {
            if file.isImage {
                ZoomablePhotoPage(
                    file: file,
                    driveId: driveId,
                    hiresRequested: hiresRequested,
                    isActive: isActive,
                    onZoomChanged: onImageZoomChanged
                )
            } else if file.isVideo {
                VideoPlayerView(
                    file: file,
                    driveId: driveId,
                    isActive: isActive,
                    onControlsInteractionChanged: onVideoControlsInteractionChanged
                )
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
    let isActive: Bool
    let onZoomChanged: (Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    /// Échelle de l'écran (2× ou 3×) : convertit la taille en points du pager
    /// en pixels pour dimensionner le décodage.
    @Environment(\.displayScale) private var displayScale
    @State private var gif: GIFImage?
    /// Image au niveau affichage (≈ 1× l'écran en pixels) : c'est elle qui
    /// s'affiche et qui est décodée pour chaque page visitée.
    @State private var displayImage: UIImage?
    /// Image à la résolution native du fichier, chargée **seulement** quand
    /// l'utilisateur zoome. Elle pèse plusieurs dizaines de mégaoctets décodée
    /// (48 Mpx ≈ 195 Mo) : la décoder pour chaque photo ouverte faisait
    /// travailler ImageIO et le GPU pour une image presque toujours réduite à
    /// l'écran.
    @State private var fullImage: UIImage?
    @State private var thumbnail: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    /// Taille de la page en pixels, relevée une seule fois (rotation comprise).
    @State private var viewportPixelSize: CGFloat = 0
    /// Demande du niveau natif : armée à la fin d'un pincement qui zoome ou par
    /// un double-tap. `isZoomed` est dérivé de `scale`, qui change à chaque
    /// image du geste : l'utiliser comme clé de tâche relancerait le
    /// téléchargement sans arrêt.
    @State private var wantsFullResolution = false

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
            // Les portraits très étroits dépassent volontairement en hauteur
            // pour conserver toute la largeur ; on rogne alors hors de la page.
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture(in: contentSize))
            .padding(.top, clearance)
        }
        .task(id: file.id) {
            await loadThumbnail()
        }
        .task(id: hiresRequestKey) {
            guard hiresRequested, !file.isGIF else { return }
            await loadDisplayImage(maximumPixelSize: viewportPixelSize)
        }
        .task(id: hiresRequested) {
            guard file.isGIF, hiresRequested else {
                gif = nil
                return
            }
            guard gif == nil else { return }
            let delays: [Duration] = [.zero, .seconds(3), .seconds(8)]
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                let loaded = await GIFImageStore.shared.image(driveId: driveId, fileId: file.id)
                guard !Task.isCancelled else { return }
                if let loaded {
                    gif = loaded
                    return
                }
            }
        }
        .task(id: wantsFullResolution) {
            // Une seule fois par page : le zoom suivant réutilise l'image déjà
            // chargée, qui reste attachée à la page tant qu'elle est montée.
            guard wantsFullResolution, fullImage == nil else { return }
            await loadFullResolutionImage()
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            // Taille de la page en pixels : dimension cible du décodage.
            max(geometry.size.width, geometry.size.height) * displayScale
        } action: { pixelSize in
            // N'écrit l'état que sur un vrai changement (rotation) : sinon la
            // mesure relancerait le corps du pager à chaque frame de geste.
            if viewportPixelSize != pixelSize { viewportPixelSize = pixelSize }
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
    private func image(in screenSize: CGSize) -> some View {
        if let gif {
            AnimatedGIFView(image: gif, isPlaying: isActive && scenePhase == .active)
                .frame(width: screenSize.width, height: screenSize.width / gif.aspectRatio)
        } else if let display {
            Image(uiImage: display)
                .resizable()
                .scaledToFit()
                // La largeur est la contrainte maîtresse : les photos étroites
                // ne laissent plus de bandes latérales dans la visionneuse.
                .frame(width: screenSize.width)
        } else {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
        }
    }

    private var display: UIImage? { fullImage ?? displayImage ?? thumbnail }

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
        image(in: screenSize)
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
                        // Un zoom demande la résolution native : c'est le seul
                        // cas où l'image d'affichage ne suffit plus.
                        wantsFullResolution = true
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
                // Le pincement est terminé : la valeur est stable, la demande
                // de résolution native part donc une seule fois.
                if scale >= 1.15 { wantsFullResolution = true }
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
    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        let image = await ThumbnailProvider.shared.thumbnail(
            driveId: driveId,
            fileId: file.id
        )
        guard !Task.isCancelled, thumbnail == nil else { return }
        thumbnail = image
    }

    /// Clé de la demande « niveau affichage » : elle dépend de la page **et**
    /// de la taille de l'écran en pixels, pour que la tâche reparte une fois la
    /// géométrie connue (rotation comprise) au lieu de décoder sans cible.
    private struct HiresRequestKey: Hashable {
        let requested: Bool
        let pixelSize: Int
    }

    private var hiresRequestKey: HiresRequestKey {
        HiresRequestKey(requested: hiresRequested, pixelSize: Int(viewportPixelSize.rounded()))
    }

    /// Image au niveau affichage (~1× l'écran en pixels) avec quelques
    /// tentatives espacées : un échec réseau ponctuel ne laisse pas la page
    /// bloquée sur la miniature. La bascule s'anime même si elle survient
    /// longtemps après l'ouverture, y compris pendant un zoom déjà en cours.
    private func loadDisplayImage(maximumPixelSize: CGFloat) async {
        // Sans géométrie connue, ne rien demander : décoder sans taille cible
        // retomberait sur la résolution native du capteur. La clé de tâche
        // (`hiresRequestKey`) relancera la demande dès que la taille arrive.
        guard displayImage == nil, maximumPixelSize > 0 else { return }
        let retryDelays: [Duration] = [.zero, .seconds(3), .seconds(8)]
        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let image = await HiresImageStore.shared.displayImage(
                driveId: driveId,
                fileId: file.id,
                maximumPixelSize: maximumPixelSize
            )
            guard !Task.isCancelled else { return }
            if let image {
                withAnimation(.easeIn(duration: 0.2)) {
                    displayImage = image
                }
                return
            }
        }
    }

    /// Niveau natif, réservé au zoom : la résolution du capteur n'est plus
    /// décodée pour une photo simplement affichée.
    private func loadFullResolutionImage() async {
        let image = await HiresImageStore.shared.fullResolutionImage(driveId: driveId, fileId: file.id)
        guard !Task.isCancelled, let image else { return }
        withAnimation(.easeIn(duration: 0.2)) {
            fullImage = image
        }
    }
}
