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
    /// Cache du calcul `visibleItems` : les filtres/tri/regroupement ne sont
    /// recalculés que si les données, les filtres, la recherche ou les
    /// métadonnées vidéo changent — pas à chaque rendu du body.
    @State private var visibleItemsCache = VisibleItemsCache()

    private var needsVideoMetadata: Bool {
        filters.sort == .duration || filters.orientation != nil
    }

    var body: some View {
        scrollContent
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

                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    content
                }
                .padding(.horizontal, DS.gridMargin)
                .padding(.top, 6 + contentTopInset)
                .padding(.bottom, 110) // barre flottante
            }
            // Même un dossier trop court pour défiler peut être tiré vers le
            // bas : ce rebond déclenche l'overscroll qui révèle la recherche.
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollIndicators(.hidden)
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

    /// Source déjà filtrée par le serveur : relancer les mots-clés en local
    /// masquerait des résultats trouvés par l'API selon des règles plus larges
    /// que `localizedStandardContains` sur le nom.
    private var effectiveSearchText: String {
        if case .search = viewModel.source { return "" }
        return searchText
    }

    /// Éléments après filtres (type, orientation, recherche) et tri.
    private var visibleItems: [DriveFile] {
        visibleItemsCache.visibleItems(
            items: viewModel.items,
            filters: filters,
            searchText: effectiveSearchText,
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
        // Compteurs compars au lieu du tableau complet des identifiants :
        // construire puis hacher `items.map(\.id)` à chaque rendu coûtait
        // O(n) sur les grands dossiers et participait aux saccades. La liste
        // n'évoluant que par ajout, compteur + dernier id suffisent ; un
        // rechargement complet bascule de toute façon `isReloading`.
        let itemCount: Int
        let lastItemID: Int?
        let filters: FileFilters
        let searchText: String
        let hasMore: Bool
        let isReloading: Bool
    }

    private var emptyFilteredPageTaskKey: EmptyFilteredPageTaskKey {
        EmptyFilteredPageTaskKey(
            itemCount: viewModel.items.count,
            lastItemID: viewModel.items.last?.id,
            filters: filters,
            searchText: effectiveSearchText,
            hasMore: viewModel.hasMore,
            isReloading: viewModel.isReloading
        )
    }

    private func grid(for files: [DriveFile]) -> some View {
        LazyVGrid(columns: columns, spacing: DS.gridSpacing) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                cell(file, index: index, siblings: files)
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
