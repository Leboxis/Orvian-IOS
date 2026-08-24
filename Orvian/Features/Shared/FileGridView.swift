import SwiftUI

/// Grille 3 colonnes réutilisable, avec pagination infinie et préchargement.
struct FileGridView: View {
    var viewModel: FileGridViewModel

    /// Groupement des sections : composant de calendrier + titre (Actualité → jour, Média → mois). nil → grille plate.
    var grouping: (component: Calendar.Component, title: (Date) -> String)?

    /// Navigation dans un dossier (onglet Fichiers uniquement).
    var onOpenDirectory: ((DriveFile) -> Void)?

    /// Ouverture d'une visionneuse (image/vidéo) avec ses voisins pour le pager.
    var onOpenFile: ((DriveFile, [DriveFile]) -> Void)?

    /// Informe l'écran parent de la liste exacte après filtres et recherche.
    /// Les actions de masse utilisent ainsi la même source que les cartes.
    var onVisibleItemsChanged: (([DriveFile]) -> Void)?

    /// Filtre client des éléments affichés (barre de recherche de l'Accueil).
    var searchText: String = ""
    
    /// Options de tri et de filtrage (bouton filtre de l'Accueil).
    var filters: FileFilters = .init()

    /// Remonte true après un court geste vers le bas depuis le haut de la liste.
    var onScrolledPastTop: ((Bool) -> Void)?

    /// Décalage ajouté en haut du contenu (barre de recherche flottante) pour
    /// que la première rangée ne soit jamais masquée.
    var contentTopInset: CGFloat = 0

    /// Pull-to-refresh (désactivé sur l'Accueil, remplacé par la barre de recherche).
    var allowsPullToRefresh = true

    /// Mode sélection : le tap coche au lieu d'ouvrir.
    var selectionMode = false

    /// Identifiants des éléments sélectionnés (mode sélection).
    var selectedIDs: Set<Int> = []

    /// Appelé quand l'utilisateur tape une carte en mode sélection.
    var onToggleSelection: ((DriveFile) -> Void)?

    /// Demande de déplacement individuel depuis une carte.
    var onMove: ((DriveFile) -> Void)?

    /// Active le glisser-déposer par appui long vers les dossiers
    /// (grilles naviguant dans l'arborescence uniquement).
    var dragDropEnabled = false

    /// Dépôt réussi sur un dossier : identifiants des éléments soulevés
    /// et dossier cible. L'écran parent orchestre le déplacement réseau.
    var onDropMove: ((Set<Int>, DriveFile) -> Void)?

    /// Jeton incrémenté par l'écran parent pour ramener la grille au début.
    /// Il ne modifie ni les filtres ni les données déjà chargées.
    var scrollToTopRequest = 0

    private let mediaMetadata = MediaMetadataStore.shared
    @AppStorage("prefetchThumbnails") private var prefetchThumbnails = true
    @AppStorage("prefetchVideoURLs") private var prefetchVideoURLs = true
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = false
    @AppStorage("fileGridColumns") private var fileGridColumns = 3
    @State private var metadataRevision = 0
    @State private var prefetchTask: Task<Void, Never>?
    @State private var sortReloadTask: Task<Void, Never>?
    @State private var searchScrollRegion: SearchScrollRegion = .nearTop
    /// Cache du calcul `visibleItems` : les filtres/tri/regroupement ne sont
    /// recalculés que si les données, les filtres, la recherche ou les
    /// métadonnées vidéo changent — pas à chaque rendu du body.
    @State private var visibleItemsCache = VisibleItemsCache()
    /// Session de glisser-déposer en cours (nil tant qu'aucun appui long).
    @State private var dragSession = GridDragSession()
    /// Cadres des cartes visibles dans l'espace de la grille, pour le suivi
    /// du doigt et la détection du dossier survolé.
    @State private var cellFrames: [Int: CellGeometry] = [:]
    /// Verrou du défilement pendant qu'un élément est transporté.
    @State private var scrollLocker = ScrollLocker()

    private var needsVideoMetadata: Bool {
        filters.sort == .duration || filters.orientation != nil || filters.highResolutionVideosOnly
    }

    var body: some View {
        scrollContent
            .onScrollGeometryChange(for: SearchScrollRegion.self, of: {
                // Au repos, iOS applique déjà l'inset supérieur au décalage.
                // Seul un dépassement réel de cette position doit afficher la recherche.
                let offset = $0.contentOffset.y + $0.contentInsets.top
                if offset < -8 {
                    return .pulledPastTop
                }
                if offset > 24 {
                    return .content
                }
                return .nearTop
            }) { _, newRegion in
                searchScrollRegion = newRegion
                switch newRegion {
                case .content:
                    onScrolledPastTop?(false)
                case .pulledPastTop:
                    onScrolledPastTop?(true)
                case .nearTop:
                    break
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .task(id: viewModel.source) {
                await viewModel.loadIfNeeded()
            }
            // Un changement de tri (dates, type, poids) relit le serveur avec
            // l'ordre demandé : la pagination entière respecte alors le tri,
            // et pas seulement les éléments déjà chargés. Un seul déclencheur
            // sur l'ensemble `filters` : changer le tri ET le sens en même
            // temps ne lance plus deux rechargements réseau.
            .onChange(of: filters) { oldFilters, newFilters in
                if oldFilters.sort != newFilters.sort || oldFilters.direction != newFilters.direction {
                    sortReloadTask?.cancel()
                    sortReloadTask = Task { await viewModel.reload(sortedBy: newFilters) }
                }
            }
            .onAppear {
                onVisibleItemsChanged?(visibleItems)
            }
            .onChange(of: visibleItems) { _, newItems in
                onVisibleItemsChanged?(newItems)
            }
            .task(id: emptyFilteredPageTaskKey) {
                await loadUntilFilteredResultIfNeeded()
            }
            .task(id: filterTaskKey) {
                guard needsVideoMetadata else { return }
                await mediaMetadata.resolveAll(driveId: viewModel.driveId, items: viewModel.items)
            }
            .onReceive(mediaMetadata.$revision) { newRev in
                if needsVideoMetadata {
                    metadataRevision = newRev
                }
            }
            .onDisappear {
                prefetchTask?.cancel()
                prefetchTask = nil
                sortReloadTask?.cancel()
                sortReloadTask = nil
            }
            // Fin de dépôt : dès que les éléments déplacés quittent la grille
            // (réponse du serveur), on referme la session sans animation pour
            // ne pas voir les cartes réapparaître un instant.
            .onChange(of: viewModel.items) { _, items in
                guard dragSession.phase == .dropping else { return }
                let remainingIDs = Set(items.map(\.id))
                guard dragSession.draggedIDs.allSatisfy({ !remainingIDs.contains($0) }) else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dragSession.reset() }
            }
            // Déplacement refusé par l'API : les cartes soulevées réapparaissent
            // immédiatement au lieu d'attendre le minuteur de sécurité.
            .onChange(of: viewModel.errorMessage) { _, errorMessage in
                guard errorMessage != nil, dragSession.phase == .dropping else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                    dragSession.reset()
                }
            }
            // Filet de sécurité : si le déplacement n'aboutit pas (erreur
            // réseau…), les cartes soulevées réapparaissent à leur place.
            .task(id: dragSession.dropStartedAt) {
                guard dragSession.dropStartedAt != nil else { return }
                try? await Task.sleep(for: .seconds(10))
                guard dragSession.phase == .dropping else { return }
                withAnimation(.easeOut(duration: 0.25)) { dragSession.reset() }
            }
            // Le scroll est réactivé dès que la session se referme, quelle
            // que soit la raison (dépôt, annulation, erreur, minuteur).
            .onChange(of: dragSession.isActive) { _, active in
                if !active { scrollLocker.setLocked(false) }
            }
            // Un geste interrompu par le système (appel, centre de contrôle…)
            // ne déclenche pas toujours `.onEnded` : sans ce minuteur, la
            // session resterait active et le scroll verrouillé pour toujours.
            .task(id: dragSession.anchorID) {
                guard dragSession.anchorID != nil else { return }
                try? await Task.sleep(for: .seconds(45))
                guard dragSession.phase == .lifting, dragSession.isActive else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                    dragSession.reset()
                }
            }
            .onDisappear {
                scrollLocker.setLocked(false)
            }
    }

    /// Relance la résolution des métadonnées vidéo uniquement quand il y a de
    /// nouvelles vidéos à résoudre : la clé repose sur l'ensemble des
    /// identifiants encore non résolus, pas sur le compteur d'éléments (qui
    /// change à chaque page chargée et relançait inutilement le travail).
    private var filterTaskKey: String {
        guard needsVideoMetadata else { return "none" }
        let pending = mediaMetadata.unresolvedVideoIDs(in: viewModel.items)
        if pending.isEmpty {
            return "resolved-\(viewModel.driveId)"
        }
        return "resolve-\(pending.sorted())"
    }

    @ViewBuilder
    private var scrollContent: some View {
        if allowsPullToRefresh {
            baseScroll
                .refreshable {
                    await viewModel.reload()
                }
        } else {
            baseScroll
        }
    }

    private var baseScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id("file-grid-top")

                ScrollLockerMarker(locker: scrollLocker)

                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    content
                }
                .padding(.horizontal, DS.gridMargin)
                .padding(.top, 6 + contentTopInset)
                .padding(.bottom, 110) // barre flottante
            }
            // Même un dossier trop court pour défiler peut être tiré vers le
            // bas : ce geste révèle la recherche sur l'Accueil.
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollIndicators(.hidden)
            // Référentiel commun des cadres de cartes et du doigt.
            .coordinateSpace(name: GridDragSpaceName)
            .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
            .sensoryFeedback(.impact(weight: .medium), trigger: dragSession.anchorID)
            .sensoryFeedback(.selection, trigger: dragSession.hoveredFolderID)
            .sensoryFeedback(.success, trigger: dragSession.dropStartedAt)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        // Secours pour les dossiers très courts : même si le
                        // ScrollView ne bouge pas visuellement, le geste révèle
                        // tout de même la recherche.
                        if searchScrollRegion != .content,
                           value.translation.height > 12,
                           value.translation.height > abs(value.translation.width) {
                            onScrolledPastTop?(true)
                        }
                    }
            )
            .onChange(of: scrollToTopRequest) { oldValue, newValue in
                guard oldValue != newValue else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    proxy.scrollTo("file-grid-top", anchor: .top)
                }
            }
        }
    }

    // MARK: - Contenu

    private var searchKeywords: [String] {
        searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private var isSearching: Bool {
        !searchKeywords.isEmpty
    }

    /// Éléments après filtres (type, orientation, recherche) et tri.
    private var visibleItems: [DriveFile] {
        visibleItemsCache.visibleItems(
            items: viewModel.items,
            filters: filters,
            searchText: searchText,
            metadataRevision: metadataRevision,
            mediaMetadata: mediaMetadata
        )
    }

    /// Message quand aucun élément ne correspond aux filtres ou à la recherche.
    private var noResultsMessage: String {
        if isSearching {
            return "Aucun fichier ne correspond à « \(searchText.trimmingCharacters(in: .whitespacesAndNewlines)) »."
        }
        return "Aucun fichier ne correspond aux filtres sélectionnés."
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isInitialLoading {
            skeleton
        } else if let message = viewModel.errorMessage, viewModel.items.isEmpty {
            errorState(message)
        } else if viewModel.items.isEmpty {
            emptyState
        } else if visibleItems.isEmpty {
            filteredEmptyState
        } else if let grouping, !isSearching && !filters.isActive {
            ForEach(viewModel.groups(by: grouping.component, title: grouping.title)) { group in
                SectionHeader(title: group.title)
                grid(for: group.files)
            }
            footer
        } else {
            grid(for: visibleItems)
            footer
        }
    }

    @ViewBuilder
    private var filteredEmptyState: some View {
        if viewModel.isLoadingMore {
            VStack(spacing: 10) {
                ProgressView()
                Text("Recherche dans les pages suivantes…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if let message = viewModel.errorMessage, viewModel.hasMore {
            ContentUnavailableView {
                Label("Chargement interrompu", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Réessayer") {
                    Task { await viewModel.loadMoreIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 60)
        } else {
            ContentUnavailableView {
                Label("Aucun résultat", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(noResultsMessage)
            }
            .padding(.top, 60)
        }
    }

    /// Une page peut ne contenir que des éléments masqués par le filtre. Sans
    /// carte visible, aucun `onAppear` ne peut déclencher la pagination. Cette
    /// boucle avance donc jusqu'au premier résultat, avec une protection contre
    /// une API qui renverrait la même page.
    private func loadUntilFilteredResultIfNeeded() async {
        guard !viewModel.isInitialLoading,
              !viewModel.items.isEmpty,
              visibleItems.isEmpty
        else { return }

        var previousItemCount = viewModel.items.count
        while !Task.isCancelled,
              visibleItems.isEmpty,
              viewModel.hasMore,
              viewModel.errorMessage == nil {
            await viewModel.loadMoreIfNeeded()
            guard !Task.isCancelled, viewModel.errorMessage == nil else { return }
            let newItemCount = viewModel.items.count
            guard newItemCount > previousItemCount else { return }
            previousItemCount = newItemCount
        }
    }

    private struct EmptyFilteredPageTaskKey: Hashable {
        let itemIDs: [Int]
        let filters: FileFilters
        let searchText: String
        let hasMore: Bool
        let isReloading: Bool
    }

    private var emptyFilteredPageTaskKey: EmptyFilteredPageTaskKey {
        EmptyFilteredPageTaskKey(
            itemIDs: viewModel.items.map(\.id),
            filters: filters,
            searchText: searchText,
            hasMore: viewModel.hasMore,
            isReloading: viewModel.isReloading
        )
    }

    private func grid(for files: [DriveFile]) -> some View {
        LazyVGrid(columns: columns, spacing: DS.gridSpacing) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                cell(file, index: index, siblings: files)
                    .modifier(DragCellTransform(
                        session: dragSession,
                        id: file.id,
                        geometry: cellFrames[file.id],
                        frames: cellFrames
                    ))
                    .modifier(FolderDropHighlight(
                        isTargeted: dragSession.phase == .lifting && dragSession.hoveredFolderID == file.id
                    ))
                    .background {
                        if dragDropEnabled {
                            CellFrameReader(file: file)
                        }
                    }
                    .simultaneousGesture(dragDropGesture(for: file))
            }
        }
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: DS.gridSpacing),
            count: min(max(fileGridColumns, 2), 7)
        )
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView()
                Text("Chargement…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if viewModel.errorMessage != nil, !viewModel.items.isEmpty {
            retryRow
        }
    }

    private var retryRow: some View {
        Button {
            Task { await viewModel.loadMoreIfNeeded() }
        } label: {
            Label("Réessayer", systemImage: "arrow.clockwise")
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Cellule

    private func cell(_ file: DriveFile, index: Int, siblings: [DriveFile]) -> some View {
        FileCardView(
            file: file,
            driveId: viewModel.driveId,
            categoriesById: viewModel.categoriesById,
            enabled: selectionMode || !file.isDirectory || onOpenDirectory != nil,
            selectionMode: selectionMode,
            isTrashed: viewModel.source == .trash,
            isSelected: selectedIDs.contains(file.id),
            showsFavoriteBadge: viewModel.source != .favorites,
            onToggleSelection: onToggleSelection == nil ? nil : { onToggleSelection?(file) },
            onToggleFavorite: {
                Task { await viewModel.toggleFavorite(file) }
            },
            onDelete: {
                Task { await viewModel.trash(file) }
            },
            onRename: { newName in
                Task { await viewModel.rename(file, name: newName) }
            },
            onMove: onMove == nil ? nil : {
                onMove?(file)
            },
            onSetColor: { color in
                Task { await viewModel.setColor(file, color: color) }
            },
            onTagChanged: { category, applied in
                viewModel.updateCategories(for: file, category: category, applied: applied)
            },
            action: {
                if selectionMode {
                    onToggleSelection?(file)
                } else if file.isDirectory {
                    onOpenDirectory?(file)
                } else {
                    onOpenFile?(file, siblings)
                }
            }
        )
        .onAppear {
            appeared(file: file, index: index, in: siblings)
        }
    }

    // MARK: - Glisser-déposer vers un dossier

    /// Appui long puis mouvement : soulève la carte (et toute la sélection
    /// courante si la carte soulevée en fait partie). Un appui long immobile
    /// continue d'ouvrir le menu contextuel — le mouvement l'annule côté
    /// système, le glisser prend le relais.
    private func dragDropGesture(for file: DriveFile) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 10, coordinateSpace: .named(GridDragSpaceName)))
            .onChanged { value in
                guard dragDropEnabled,
                      viewModel.source != .trash,
                      case .second(_, .some(let drag)) = value
                else { return }
                if !dragSession.isActive {
                    startDrag(anchor: file, at: drag.startLocation)
                }
                dragSession.location = drag.location
                dragSession.updateHover(frames: cellFrames)
            }
            .onEnded { value in
                guard case .second = value else { return }
                endDrag()
            }
    }

    /// Éléments soulevés : la sélection entière si la carte en fait partie,
    /// sinon la seule carte touchée.
    private func startDrag(anchor: DriveFile, at point: CGPoint) {
        var ids: [Int]
        if selectionMode, selectedIDs.contains(anchor.id) {
            ids = visibleItems.filter { selectedIDs.contains($0.id) }.map(\.id)
        } else {
            ids = [anchor.id]
        }
        if !ids.contains(anchor.id) { ids.append(anchor.id) }
        guard !ids.isEmpty else { return }

        // Le défilement est coupé au niveau UIKit : les cadres restent stables
        // pour le survol des dossiers, sans invalider les gestes SwiftUI.
        scrollLocker.setLocked(true)

        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            dragSession.begin(ids: ids, anchorID: anchor.id, at: point)
        }
    }

    /// Relâchement : dépôt dans le dossier survolé s'il est valide,
    /// sinon retour animé de chaque carte à sa place.
    private func endDrag() {
        guard dragSession.phase == .lifting, dragSession.isActive else { return }

        if let target = validatedDropTarget() {
            let ids = Set(dragSession.draggedIDs)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                dragSession.beginDrop(into: target.id)
            }
            // Laisse la gerbe plonger dans le dossier avant le déplacement
            // réseau ; la grille refermera la session quand les cartes
            // disparaîtront de la liste (voir `.onChange(of: viewModel.items)`).
            let callback = onDropMove
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                callback?(ids, target)
            }
        } else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                dragSession.reset()
            }
        }
    }

    /// Dossier survolé réellement déplaçable : pas un élément soulevé, pas
    /// le dossier courant (déplacement sans effet).
    private func validatedDropTarget() -> DriveFile? {
        guard let folderID = dragSession.hoveredFolderID,
              cellFrames[folderID]?.isDirectory == true,
              !dragSession.draggedIDs.contains(folderID),
              let folder = viewModel.items.first(where: { $0.id == folderID })
        else { return nil }
        if case .directory(let currentDirectoryID) = viewModel.source,
           currentDirectoryID == folderID {
            return nil
        }
        return folder
    }

    /// Apparition d'une carte : pagination immédiate, puis préchargement d'une
    /// seule rangée après une courte accalmie. Un scroll rapide annule ainsi le
    /// travail prévu pour les cartes déjà dépassées.
    private func appeared(file: DriveFile, index: Int, in siblings: [DriveFile]) {
        if index >= siblings.count - 6 {
            Task { await viewModel.loadMoreIfNeeded() }
        }

        let ahead = siblings.dropFirst(index + 1).prefix(3)
        let thumbnailIds = ahead.filter { $0.fileKind.supportsThumbnail }.map(\.id)
        let videoIds = viewModel.source == .trash
            ? []
            : Array(ahead.lazy.filter(\.isVideo).prefix(2).map(\.id))
        let driveId = viewModel.driveId
        let isTrashed = viewModel.source == .trash

        prefetchTask?.cancel()
        guard prefetchThumbnails || prefetchVideoURLs,
              !prefetchOnWiFiOnly || NetworkMonitor.shared.allowsBackgroundPrefetch
        else { return }

        prefetchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            if prefetchThumbnails, !thumbnailIds.isEmpty {
                await ThumbnailProvider.shared.prefetch(
                    driveId: driveId,
                    fileIds: Array(thumbnailIds),
                    isTrashed: isTrashed
                )
            }
            if prefetchVideoURLs, !videoIds.isEmpty {
                await VideoAssetCache.shared.prefetch(driveId: driveId, fileIds: videoIds)
            }
        }
    }

    // MARK: - États

    private var skeleton: some View {
        LazyVGrid(columns: columns, spacing: DS.gridSpacing) {
            ForEach(0..<9, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: emptySymbol,
            title: emptyTitle,
            message: "Tirez vers le bas pour rafraîchir."
        )
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Impossible de charger", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Réessayer") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptySymbol: String {
        switch viewModel.source {
        case .directory: return "folder"
        case .favorites: return "star"
        case .recents: return "clock"
        case .mostViewed: return "flame"
        case .category: return "tag"
        case .trash: return "trash"
        case .search: return "magnifyingglass"
        }
    }

    private var emptyTitle: String {
        switch viewModel.source {
        case .directory: return "Dossier vide"
        case .favorites: return "Aucun favori"
        case .recents: return "Aucun upload récent"
        case .mostViewed: return "Aucun média consulté"
        case .category: return "Aucun fichier avec ce tag"
        case .trash: return "Corbeille vide"
        case .search: return "Aucun résultat"
        }
    }
}

/// Zones stables utilisées pour révéler la recherche sans publier un nouvel
/// état SwiftUI à chaque point parcouru pendant le défilement.
private enum SearchScrollRegion: Equatable {
    case pulledPastTop
    case nearTop
    case content
}

/// Mémoïse le résultat des filtres/tri de la grille : tant que les données
/// (items), les filtres, la recherche et la révision des métadonnées vidéo
/// n'ont pas changé, la liste visible n'est pas recalculée à chaque rendu.
@MainActor
private struct VisibleItemsCache {
    private struct Key: Hashable {
        let items: [DriveFile]
        let filters: FileFilters
        let searchText: String
        let metadataRevision: Int
    }

    private var cachedKey: Key?
    private var cachedResult: [DriveFile] = []

    mutating func visibleItems(
        items: [DriveFile],
        filters: FileFilters,
        searchText: String,
        metadataRevision: Int,
        mediaMetadata: MediaMetadataStore
    ) -> [DriveFile] {
        let key = Key(
            items: items,
            filters: filters,
            searchText: searchText,
            metadataRevision: metadataRevision
        )
        if key == cachedKey {
            return cachedResult
        }
        cachedKey = key
        cachedResult = filters.visible(items, searchText: searchText, mediaMetadata: mediaMetadata)
        return cachedResult
    }
}
