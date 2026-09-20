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

    /// Pull-to-refresh, actif sur tous les écrans (Accueil, Favoris, Corbeille).
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
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = true
    @AppStorage("fileGridColumns") private var fileGridColumns = 3
    @AppStorage("foldersFirstInTags") private var foldersFirstInTags = true
    /// Préférence globale : affiche l'étoile des favoris sur les cartes,
    /// y compris dans l'onglet Favoris où elle était autrefois masquée d'office.
    @AppStorage("showFavoriteStars") private var showFavoriteStars = true
    @State private var metadataRevision = 0
    @State private var prefetchTask: Task<Void, Never>?
    /// Demande de préchargement la plus récente. Une rafale d'apparitions de
    /// cartes pendant le scroll ne fait que remplacer cette demande : la
    /// tâche d'accalmie unique la relit, au lieu d'être annulée et recréée
    /// (coût + allocation) à chaque carte.
    @State private var pendingPrefetch: PrefetchRequest?
    @State private var paginationTask: Task<Void, Never>?
    @State private var paginationRequestID: UUID?
    @State private var sortReloadTask: Task<Void, Never>?
    @State private var mutationReloadTask: Task<Void, Never>?
    @State private var videoMetadataResolutionCount = 0
    /// Fiche détails demandée par une carte (une seule feuille pour toute la grille).
    @State private var detailRequest: FilePresentation?
    /// Éditeur de tags demandé par une carte.
    @State private var tagsRequest: FilePresentation?
    /// Sélecteur de couleur demandé par une carte (dossiers).
    @State private var colorRequest: FilePresentation?
    /// Confirmation de suppression demandée par une carte.
    @State private var deleteRequest: FilePresentation?
    /// Alerte de renommage demandée par une carte.
    @State private var renameRequest: FilePresentation?
    /// Texte de l'alerte de renommage, conservé entre l'ouverture et la validation.
    @State private var renameText = ""
    /// Cache du calcul `visibleItems` : les filtres/tri/regroupement ne sont
    /// recalculés que si les données, les filtres, la recherche ou les
    /// métadonnées vidéo changent — pas à chaque rendu du body.
    @State private var visibleItemsCache = VisibleItemsCache()

    private var needsVideoMetadata: Bool {
        filters.sort == .duration || filters.orientation != nil || filters.highResolutionVideosOnly
    }

    var body: some View {
        scrollContent
            .background(Color(uiColor: .systemGroupedBackground))
            .task(id: viewModel.source) {
                await viewModel.loadIfNeeded()
            }
            // Un déclencheur de pagination avalé pendant un rechargement ne
            // se répète pas tout seul (`onAppear` déjà consommé pour ces
            // cartes) : relancer une fois le rechargement terminé, sinon la
            // grille reste figée sur sa première page sans erreur visible.
            // Sans effet quand `hasMore` est faux.
            .onChange(of: viewModel.isReloading) { oldValue, newValue in
                if oldValue, !newValue {
                    requestMoreFiles()
                }
            }
            // Un changement de tri (dates, type, poids) relit le serveur avec
            // l'ordre demandé : la pagination entière respecte alors le tri,
            // et pas seulement les éléments déjà chargés. Un seul déclencheur
            // sur l'ensemble `filters` : changer le tri ET le sens en même
            // temps ne lance plus deux rechargements réseau.
            .onChange(of: filters) { oldFilters, newFilters in
                if oldFilters.sort != newFilters.sort || oldFilters.direction != newFilters.direction {
                    let oldServerSort = oldFilters.serverOrderBy
                    let newServerSort = newFilters.serverOrderBy
                    guard oldServerSort != nil || newServerSort != nil else { return }
                    guard oldServerSort != newServerSort
                            || (newServerSort != nil && oldFilters.direction != newFilters.direction) else { return }
                    sortReloadTask?.cancel()
                    sortReloadTask = Task {
                        await viewModel.reload(sortedBy: newFilters, forceNetwork: true, refreshCount: false)
                    }
                }
            }
            .onAppear {
                onVisibleItemsChanged?(visibleItems)
            }
            // La clé de mémoïsation change exactement quand la liste visible
            // peut avoir changé : comparer la clé (O(1)) remplace la
            // comparaison du tableau complet à chaque rendu.
            .onChange(of: visibleItemsKey) { _, _ in
                onVisibleItemsChanged?(visibleItems)
            }
            .task(id: emptyFilteredPageTaskKey) {
                await loadUntilFilteredResultIfNeeded()
            }
            .task(id: filterTaskKey) {
                await resolveVideoMetadata(for: viewModel.items)
            }
            .onReceive(FileGridMutationCenter.shared.mutations) { mutation in
                guard mutation.driveId == viewModel.driveId else { return }
                if viewModel.apply(mutation) {
                    scheduleMutationReload()
                }
            }
            .modifier(MetadataRevisionGate(
                needsVideoMetadata: needsVideoMetadata,
                metadata: mediaMetadata,
                onUpdate: { metadataRevision = $0 }
            ))
            .onDisappear {
                paginationTask?.cancel()
                paginationTask = nil
                paginationRequestID = nil
                prefetchTask?.cancel()
                prefetchTask = nil
                pendingPrefetch = nil
                sortReloadTask?.cancel()
                sortReloadTask = nil
                mutationReloadTask?.cancel()
                mutationReloadTask = nil
            }
            .alert("Action impossible", isPresented: mutationErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.mutationErrorMessage ?? "")
            }
            .sheet(item: $detailRequest) { request in
                FileDetailSheet(
                    file: currentFile(matching: request),
                    driveId: viewModel.driveId,
                    isTrashed: viewModel.source == .trash,
                    onOpen: { open(request: request) },
                    onToggleFavorite: { await viewModel.toggleFavorite(request.file) },
                    onDelete: { Task { await viewModel.trash(request.file) } },
                    onRename: { newName in
                        Task { await viewModel.rename(request.file, name: newName) }
                    },
                    onMove: onMove == nil ? nil : { onMove?(request.file) }
                )
            }
            .sheet(item: $tagsRequest) { request in
                TagsEditorSheet(
                    driveId: viewModel.driveId,
                    file: currentFile(matching: request),
                    onChanged: { category, applied in
                        viewModel.updateCategories(for: request.file, category: category, applied: applied)
                    }
                )
            }
            .sheet(item: $colorRequest) { request in
                FolderColorPickerSheet(
                    file: currentFile(matching: request),
                    onSetColor: { color in
                        Task { await viewModel.setColor(request.file, color: color) }
                    }
                )
            }
            .alert(
                "Supprimer",
                isPresented: deleteAlertBinding,
                presenting: deleteRequest
            ) { request in
                Button("Supprimer", role: .destructive) {
                    Task { await viewModel.trash(request.file) }
                }
                Button("Annuler", role: .cancel) {}
            } message: { request in
                Text("« \(request.file.name) » sera déplacé dans la corbeille.")
            }
            .alert(
                "Renommer",
                isPresented: renameAlertBinding,
                presenting: renameRequest
            ) { request in
                TextField("Nouveau nom", text: $renameText)
                Button("Renommer") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Task { await viewModel.rename(request.file, name: trimmed) }
                    }
                    renameText = ""
                }
                Button("Annuler", role: .cancel) { renameText = "" }
            } message: { request in
                Text("Ancien nom : \(request.file.name)")
            }
            // Les présentations vivaient sur les cartes : une carte dont
            // l'élément quittait la grille démontait sa feuille (suppression
            // depuis la fiche, retrait des favoris…). La grille referme donc
            // ses présentations quand leur fichier disparaît de la liste.
            .onChange(of: viewModel.itemsRevision) { _, _ in
                if isMissing(detailRequest) { detailRequest = nil }
                if isMissing(tagsRequest) { tagsRequest = nil }
                if isMissing(colorRequest) { colorRequest = nil }
                if isMissing(deleteRequest) { deleteRequest = nil }
                if isMissing(renameRequest) { renameRequest = nil }
            }
    }

    // MARK: - Présentations contextuelles

    /// Fichier ciblé par une présentation de la grille, avec les voisins du
    /// pager pour l'ouverture depuis la fiche détails.
    private struct FilePresentation: Identifiable {
        let file: DriveFile
        var siblings: [DriveFile] = []
        var id: Int { file.id }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteRequest != nil },
            set: { if !$0 { deleteRequest = nil } }
        )
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameRequest != nil },
            set: { if !$0 { renameRequest = nil } }
        )
    }

    /// Version la plus récente du fichier présenté : une mutation confirmée
    /// pendant l'ouverture (renommage depuis la fiche…) doit se refléter dans
    /// la feuille, comme lorsque celle-ci vivait sur la carte re-rendue.
    private func currentFile(matching request: FilePresentation) -> DriveFile {
        viewModel.items.first { $0.id == request.file.id } ?? request.file
    }

    private func isMissing(_ request: FilePresentation?) -> Bool {
        guard let request else { return false }
        return !viewModel.items.contains { $0.id == request.file.id }
    }

    /// Ouvre la présentation demandée par une carte. Une seule occurrence de
    /// chaque feuille/alerte est montée au niveau de la grille : le view-graph
    /// ne porte plus ces modificateurs sur chacune des cartes.
    private func present(_ intent: FileCardView.Intent, for file: DriveFile, siblings: [DriveFile]) {
        switch intent {
        case .details:
            detailRequest = FilePresentation(file: file, siblings: siblings)
        case .colorPicker:
            colorRequest = FilePresentation(file: file)
        case .tags:
            tagsRequest = FilePresentation(file: file)
        case .rename:
            renameText = file.name
            renameRequest = FilePresentation(file: file)
        case .deleteConfirm:
            deleteRequest = FilePresentation(file: file)
        }
    }

    /// Ouverture depuis la fiche détails : même routage que le tap sur la
    /// carte, avec les voisins capturés au moment de la demande (le pager
    /// navigue dans l'ordre du tri et des filtres affichés).
    private func open(request: FilePresentation) {
        let file = request.file
        if file.isDirectory {
            onOpenDirectory?(file)
        } else {
            onOpenFile?(file, request.siblings)
        }
    }

    private var mutationErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.mutationErrorMessage != nil },
            set: { if !$0 { viewModel.clearMutationError() } }
        )
    }

    /// Une mutation peut faire entrer un élément absent dans Favoris, Tag ou
    /// Corbeille. Regrouper les publications rapprochées évite une rafale de
    /// rechargements de liste, sans jamais répéter l'API de mutation.
    private func scheduleMutationReload() {
        mutationReloadTask?.cancel()
        mutationReloadTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await viewModel.reload(forceNetwork: true)
        }
    }

    /// Relance la résolution des métadonnées vidéo quand le contenu change :
    /// la clé repose sur la version incrémentale de la liste (coût O(1) par
    /// rendu) au lieu d'une empreinte recalculée sur toutes les vidéos à
    /// chaque rendu. La résolution déduplique elle-même (mémoire, disque,
    /// requêtes en vol) : une relance sans vidéo nouvelle ne coûte rien.
    private var filterTaskKey: String {
        guard needsVideoMetadata else { return "none" }
        return "resolve-\(viewModel.driveId)-\(viewModel.source)-\(viewModel.itemsRevision)"
    }

    @ViewBuilder
    private var scrollContent: some View {
        if allowsPullToRefresh {
            baseScroll
                .refreshable {
                    // Geste explicite de l'utilisateur : état serveur garanti.
                    await viewModel.reload(forceNetwork: true)
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
                .padding(.bottom, DS.floatingBarInset) // barre flottante
                // Bloc centré et borné en largeur : sur iPad, les colonnes
                // s'étiraient sur toute la largeur de l'écran.
                .frame(maxWidth: DS.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            // Le rebond permanent permet le pull-to-refresh même quand le
            // dossier est trop court pour défiler.
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
    /// La clé de mémoïsation est purement incrémentale : sa comparaison est
    /// O(1) au lieu de relire tout le tableau à chaque rendu.
    private var visibleItems: [DriveFile] {
        visibleItemsCache.visibleItems(
            key: visibleItemsKey,
            items: viewModel.items,
            mediaMetadata: mediaMetadata
        )
    }

    private var visibleItemsKey: VisibleItemsKey {
        VisibleItemsKey(
            source: viewModel.source,
            driveId: viewModel.driveId,
            itemsRevision: viewModel.itemsRevision,
            filters: filters,
            searchText: effectiveSearchText,
            metadataRevision: metadataRevision,
            foldersFirst: foldersFirstInTags && sourceIsCategory
        )
    }

    /// Vrai quand la grille affiche le contenu d'un tag (source `.category`).
    private var sourceIsCategory: Bool {
        if case .category = viewModel.source { return true }
        return false
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
        if videoMetadataResolutionCount > 0 {
            VStack(spacing: 10) {
                ProgressView()
                Text("Analyse des vidéos…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if viewModel.isLoadingMore {
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
                    requestMoreFiles()
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

        // Les filtres dependant des metadonnees doivent d'abord analyser la
        // page presente. Sans cette attente, chaque video encore inconnue etait
        // consideree comme masquee et declenchait une pagination prematuree.
        await resolveVideoMetadata(for: viewModel.items)
        guard !Task.isCancelled,
              visibleItems.isEmpty
        else { return }

        var previousItemCount = viewModel.items.count
        while !Task.isCancelled,
              visibleItems.isEmpty,
              viewModel.hasMore,
              viewModel.errorMessage == nil {
            await loadMoreAfterMetadataResolution()
            guard !Task.isCancelled, viewModel.errorMessage == nil else { return }
            let newItemCount = viewModel.items.count
            guard newItemCount > previousItemCount else { return }
            if needsVideoMetadata {
                await resolveVideoMetadata(for: Array(viewModel.items.dropFirst(previousItemCount)))
                guard !Task.isCancelled else { return }
            }
            previousItemCount = newItemCount
        }
    }

    private func resolveVideoMetadata(for items: [DriveFile]) async {
        guard needsVideoMetadata, !items.isEmpty else { return }
        videoMetadataResolutionCount += 1
        defer { videoMetadataResolutionCount -= 1 }
        await mediaMetadata.resolveAll(driveId: viewModel.driveId, items: items)
    }

    private func requestMoreFiles() {
        guard paginationTask == nil else { return }
        let requestID = UUID()
        paginationRequestID = requestID
        paginationTask = Task {
            defer {
                if paginationRequestID == requestID {
                    paginationTask = nil
                    paginationRequestID = nil
                }
            }
            await loadMoreAfterMetadataResolution()
        }
    }

    private func loadMoreAfterMetadataResolution() async {
        await resolveVideoMetadata(for: viewModel.items)
        guard !Task.isCancelled else { return }
        await viewModel.loadMoreIfNeeded()
    }

    private struct EmptyFilteredPageTaskKey: Hashable {
        /// Version incrémentale du contenu : toute mutation de la liste
        /// change la clé, sans recalculer une empreinte O(n) à chaque rendu.
        let source: FileSource
        let itemsRevision: Int
        let filters: FileFilters
        let searchText: String
        let hasMore: Bool
        let isReloading: Bool
    }

    private var emptyFilteredPageTaskKey: EmptyFilteredPageTaskKey {
        EmptyFilteredPageTaskKey(
            source: viewModel.source,
            itemsRevision: viewModel.itemsRevision,
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
            requestMoreFiles()
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
            showsFavoriteBadge: showFavoriteStars,
            onToggleSelection: onToggleSelection == nil ? nil : { onToggleSelection?(file) },
            onToggleFavorite: {
                Task { await viewModel.toggleFavorite(file) }
            },
            onMove: onMove == nil ? nil : {
                onMove?(file)
            },
            onPresent: { intent in
                present(intent, for: file, siblings: siblings)
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
    /// seule rangée après une courte accalmie. Les apparitions d'une rafale
    /// de scroll remplacent la demande en attente ; la tâche unique repart
    /// pour un nouveau délai avec la demande la plus récente, si bien que le
    /// travail prévu pour les cartes déjà dépassées n'est plus exécuté.
    private func appeared(file: DriveFile, index: Int, in siblings: [DriveFile]) {
        if index >= siblings.count - 6 {
            requestMoreFiles()
        }

        let ahead = siblings.dropFirst(index + 1).prefix(3)
        if prefetchThumbnails || prefetchVideoURLs,
           !prefetchOnWiFiOnly || NetworkMonitor.shared.allowsBackgroundPrefetch {
            pendingPrefetch = PrefetchRequest(
                driveId: viewModel.driveId,
                isTrashed: viewModel.source == .trash,
                thumbnailIds: prefetchThumbnails
                    ? ahead.filter { $0.fileKind.supportsThumbnail }.map(\.id) : [],
                videoIds: viewModel.source == .trash
                    ? [] : Array(ahead.lazy.filter(\.isVideo).prefix(2).map(\.id))
            )
        } else {
            pendingPrefetch = nil
        }
        guard pendingPrefetch != nil else { return }
        guard prefetchTask == nil else { return }

        prefetchTask = Task {
            while !Task.isCancelled {
                guard let request = pendingPrefetch else { break }
                pendingPrefetch = nil
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    break
                }
                if prefetchThumbnails, !request.thumbnailIds.isEmpty {
                    await ThumbnailProvider.shared.prefetch(
                        driveId: request.driveId,
                        fileIds: request.thumbnailIds,
                        isTrashed: request.isTrashed
                    )
                }
                if prefetchVideoURLs, !request.videoIds.isEmpty {
                    await VideoAssetCache.shared.prefetch(
                        driveId: request.driveId,
                        fileIds: request.videoIds
                    )
                }
            }
            prefetchTask = nil
        }
    }

    /// Demande de préchargement issue des cartes qui viennent d'apparaître.
    private struct PrefetchRequest {
        let driveId: Int
        let isTrashed: Bool
        let thumbnailIds: [Int]
        let videoIds: [Int]
    }

    // MARK: - États

    private var skeleton: some View {
        LazyVGrid(columns: columns, spacing: DS.gridSpacing) {
            ForEach(0..<9, id: \.self) { _ in
                // Le squelette reprend la hauteur finale d'une carte (vignette
                // carrée + deux lignes de texte) : le contenu ne se décale plus
                // quand les données remplacent le chargement.
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                        .aspectRatio(1, contentMode: .fit)
                    RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous)
                        .fill(.quaternary.opacity(0.3))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous)
                        .fill(.quaternary.opacity(0.25))
                        .frame(width: 34, height: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        case .category: return "Aucun fichier avec ce tag"
        case .trash: return "Corbeille vide"
        case .search: return "Aucun résultat"
        }
    }
}

/// N'observe la révision du store global de métadonnées que si les filtres
/// courants en dépendent. Sans ce garde structurel, la lecture de
/// `mediaMetadata.revision` dans le corps de la grille abonnait **toutes**
/// les grilles montées au store global : chaque lot de métadonnées résolu
/// n'importe où dans l'app (pager, favoris, corbeille…) provoquait un
/// re-rendu de chaque grille, y compris en plein défilement.
private struct MetadataRevisionGate: ViewModifier {
    let needsVideoMetadata: Bool
    let metadata: MediaMetadataStore
    let onUpdate: (Int) -> Void

    func body(content: Content) -> some View {
        if needsVideoMetadata {
            content.onChange(of: metadata.revision) { _, newRevision in
                onUpdate(newRevision)
            }
        } else {
            content
        }
    }
}

/// Clé de mémoïsation du résultat des filtres/tri de la grille : la version
/// incrémentale du contenu (itemsRevision) remplace la comparaison du
/// tableau complet — tant que les données, les filtres, la recherche et la
/// révision des métadonnées vidéo n'ont pas changé, la liste visible n'est
/// pas recalculée à chaque rendu. La source et le drive protègent du
/// remplacement du vue-modèle (recherche ↔ dossier) dans la même vue.
fileprivate struct VisibleItemsKey: Hashable {
    let source: FileSource
    let driveId: Int
    let itemsRevision: Int
    let filters: FileFilters
    let searchText: String
    let metadataRevision: Int
    let foldersFirst: Bool
}

/// Mémoïse le résultat des filtres/tri de la grille.
@MainActor
private struct VisibleItemsCache {
    private var cachedKey: VisibleItemsKey?
    private var cachedResult: [DriveFile] = []

    /// Mémoïse la passe filtres + tri + repli « dossiers d'abord ». Ce
    /// repli vivait dans la vue (refait O(n) à chaque évaluation du
    /// corps) ; il ne dépend que de la clé, il est donc calculé une
    /// seule fois ici, au même titre que les filtres.
    mutating func visibleItems(
        key: VisibleItemsKey,
        items: [DriveFile],
        mediaMetadata: MediaMetadataStore
    ) -> [DriveFile] {
        if key == cachedKey {
            return cachedResult
        }
        cachedKey = key
        var result = key.filters.visible(
            items,
            searchText: key.searchText,
            metadata: mediaMetadata.snapshot(driveId: key.driveId, items: items)
        )
        if key.foldersFirst {
            result = result.filter(\.isDirectory) + result.filter { !$0.isDirectory }
        }
        cachedResult = result
        return result
    }
}
