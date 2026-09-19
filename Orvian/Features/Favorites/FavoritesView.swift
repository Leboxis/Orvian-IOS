import SwiftUI

struct FavoritesView: View {
    @State private var viewModel: FileGridViewModel
    @State private var filters = FileFilters()
    private let router: ViewerRouter
    @Binding var path: [DriveFile]
    let scrollToTopRequest: Int

    @State private var searchText = ""
    @State private var searchRevealed = false
    @FocusState private var searchFocused: Bool
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false

    @State private var fetchingAllFavorites = false
    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var visibleItemsReport: VisibleItemsReport?
    @State private var pendingMove: MoveRequest?
    @State private var pendingTags: TagRequest?
    @State private var moveBusy = false
    @State private var deleteBusy = false
    @State private var showDeleteConfirm = false

    init(
        driveId: Int,
        router: ViewerRouter,
        path: Binding<[DriveFile]>,
        scrollToTopRequest: Int = 0
    ) {
        self.router = router
        self._path = path
        self.scrollToTopRequest = scrollToTopRequest
        _viewModel = State(initialValue: FileGridViewModel(source: .favorites, driveId: driveId))
    }

    private struct MoveRequest: Identifiable {
        let id = UUID()
        let files: [DriveFile]
    }

    private struct TagRequest: Identifiable {
        let id = UUID()
        let files: [DriveFile]
    }

    private struct VisibleItemsContext: Equatable {
        let viewModelID: ObjectIdentifier
        let source: FileSource
        let itemsRevision: Int
        let filters: FileFilters
        let searchText: String
    }

    private struct VisibleItemsReport {
        let context: VisibleItemsContext
        let items: [DriveFile]
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchBarVisible: Bool {
        alwaysShowSearch || searchFocused || isSearching || searchRevealed
    }

    private var currentVisibleItemsContext: VisibleItemsContext {
        VisibleItemsContext(
            viewModelID: ObjectIdentifier(viewModel),
            source: viewModel.source,
            itemsRevision: viewModel.itemsRevision,
            filters: filters,
            searchText: searchText
        )
    }

    private var visibleSelectionItems: [DriveFile] {
        guard visibleItemsReport?.context == currentVisibleItemsContext else { return [] }
        return visibleItemsReport?.items ?? []
    }

    private var visibleSelectionIDs: Set<Int> {
        Set(visibleSelectionItems.map(\.id))
    }

    private var actionableSelectedIDs: Set<Int> {
        selectedIDs.intersection(visibleSelectionIDs)
    }

    private var allSelected: Bool {
        !visibleSelectionIDs.isEmpty && selectedIDs.isSuperset(of: visibleSelectionIDs)
    }

    private var selectionTitle: String {
        let count = actionableSelectedIDs.count
        guard count > 0 else { return "Sélection" }
        return "\(count) sélectionné\(count > 1 ? "s" : "")"
    }

    private var reportedVisibleItemCount: Int? {
        guard visibleItemsReport?.context == currentVisibleItemsContext else { return nil }
        return visibleItemsReport?.items.count
    }

    private var displayedItemCount: Int? {
        guard viewModel.itemsRevision > 0, !viewModel.isInitialLoading else { return nil }
        if isSearching || hasCountFiltering {
            return reportedVisibleItemCount
        }
        return viewModel.totalItemCount ?? reportedVisibleItemCount ?? viewModel.items.count
    }

    private var itemCountText: String {
        guard let count = displayedItemCount else {
            return hasCountFiltering || isSearching ? "Filtrage…" : "Chargement…"
        }
        let plural = count > 1
        if isSearching {
            return "\(count) résultat\(plural ? "s" : "")"
        }
        if usesVisibleItemCount {
            return "\(count) élément\(plural ? "s" : "") visible\(plural ? "s" : "")"
        }
        return "\(count) élément\(plural ? "s" : "")"
    }

    private var usesVisibleItemCount: Bool {
        isSearching || hasCountFiltering
    }

    private var hasCountFiltering: Bool {
        filters.orientation != nil
            || filters.highResolutionVideosOnly
            || filters.media != .all
            || filters.filesOnly
    }

    private var playableFiles: [DriveFile] {
        Array(viewModel.items).filter { !$0.isDirectory }
    }

    private func fetchAllFavorites() async -> [DriveFile] {
        let service = KDriveService()
        var allFiles: [DriveFile] = []
        var cursor: String? = nil
        repeat {
            guard let page = try? await service.page(
                .favorites(limit: 60), driveId: viewModel.driveId, cursor: cursor, forceNetwork: true
            ) else { break }
            allFiles.append(contentsOf: Array(page.data ?? []).filter { !$0.isDirectory })
            cursor = page.cursor
        } while cursor != nil
        return allFiles
    }

    var body: some View {
        let visibleItemsContext = currentVisibleItemsContext
        NavigationStack(path: $path) {
            FileGridView(
                viewModel: viewModel,
                onOpenDirectory: { folder in
                    searchFocused = false
                    path.append(folder)
                },
                onOpenFile: { file, siblings in
                    searchFocused = false
                    router.open(
                        file,
                        siblings: siblings,
                        filters: filters,
                        searchText: searchText,
                        viewModel: viewModel
                    )
                },
                onVisibleItemsChanged: { items in
                    updateVisibleSelectionItems(items, context: visibleItemsContext)
                },
                searchText: searchText,
                filters: filters,
                allowsPullToRefresh: true,
                selectionMode: selectionMode,
                selectedIDs: selectedIDs,
                onToggleSelection: { toggleSelection($0) },
                onMove: { prepareMove(files: [$0]) },
                scrollToTopRequest: scrollToTopRequest
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !selectionMode {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            itemCountLabel
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)

                        if searchBarVisible {
                            searchBar
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .animation(.snappy(duration: 0.25), value: searchBarVisible)
                }
            }
            .toolbar {
                if selectionMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            endSelection()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("Annuler la sélection")
                    }

                    ToolbarItem(placement: .principal) {
                        Text(selectionTitle)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            toggleAll()
                        } label: {
                            Image(systemName: allSelected ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .accessibilityLabel(allSelected ? "Tout désélectionner" : "Tout sélectionner")

                        Button {
                            prepareTagSheet()
                        } label: {
                            Image(systemName: "tag")
                        }
                        .disabled(actionableSelectedIDs.isEmpty)
                        .accessibilityLabel("Mettre des tags")

                        Button {
                            prepareSelectedMove()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .disabled(actionableSelectedIDs.isEmpty || moveBusy)
                        .accessibilityLabel("Déplacer")

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(actionableSelectedIDs.isEmpty || deleteBusy)
                        .accessibilityLabel("Supprimer")
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        FilterMenu(filters: $filters)
                        searchToggleButton
                    }

                    ToolbarItem(placement: .principal) {
                        Text("Favoris")
                            .font(.headline)
                            .lineLimit(1)
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        randomFileButton

                        Button {
                            startSelection()
                        } label: {
                            Label("Sélectionner", systemImage: "checkmark.circle")
                        }
                        .disabled(visibleSelectionItems.isEmpty || moveBusy)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if moveBusy || deleteBusy {
                    busyIndicator
                }
            }
            .sheet(item: $pendingMove) { request in
                MoveDestinationPicker(
                    driveId: viewModel.driveId,
                    itemCount: request.files.count,
                    excludedDirectoryIDs: Set(request.files.filter(\.isDirectory).map(\.id)),
                    unavailableDestinationIDs: unavailableDestinationIDs(for: request.files),
                    parentDirectory: nil,
                    onSelect: { destination in
                        pendingMove = nil
                        Task { await move(request.files, to: destination) }
                    }
                )
            }
            .sheet(item: $pendingTags) { request in
                ApplyTagsSheet(
                    driveId: viewModel.driveId,
                    files: request.files,
                    onDone: { changes in
                        Task { await refreshAfterTags(changes) }
                    }
                )
            }
            .confirmationDialog(
                "Supprimer \(actionableSelectedIDs.count) élément\(actionableSelectedIDs.count > 1 ? "s" : "") ?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Déplacer vers la corbeille", role: .destructive) {
                    Task { await deleteSelected() }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les éléments sélectionnés seront déplacés dans la corbeille.")
            }
            .onChange(of: searchText) { _, _ in
                if selectionMode { endSelection() }
            }
            .navigationDestination(for: DriveFile.self) { directory in
                let index = path.firstIndex(where: { $0.id == directory.id })
                let crumbs = ["Favoris"] + (index.map { Array(path[...$0].map(\.name)) } ?? [])
                DirectoryView(
                    directory: directory,
                    driveId: viewModel.driveId,
                    crumbs: crumbs,
                    router: router,
                    onOpenFolder: { folder in
                        path.append(folder)
                    }
                )
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                "Rechercher dans les favoris…",
                text: $searchText
            )
            .focused($searchFocused)
            .autocorrectionDisabled()
            .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .inputChrome(Capsule())
        .frame(maxWidth: 260)
    }

    private var searchToggleButton: some View {
        Button {
            if searchFocused || searchBarVisible {
                searchFocused = false
                if !alwaysShowSearch {
                    searchRevealed = false
                }
            } else {
                searchRevealed = true
                DispatchQueue.main.async {
                    searchFocused = true
                }
            }
        } label: {
            Image(systemName: searchBarVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
        }
        .accessibilityLabel(searchBarVisible ? "Fermer la recherche" : "Ouvrir la recherche")
        .accessibilityHint("Affiche ou masque la barre de recherche")
    }

    private var randomFileButton: some View {
        Button {
            openRandomFile()
        } label: {
            Image(systemName: "dice")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(playableFiles.isEmpty || fetchingAllFavorites)
        .accessibilityLabel("Ouvrir un fichier au hasard")
    }

    private func openRandomFile() {
        Task {
            fetchingAllFavorites = true
            let all = await fetchAllFavorites()
            fetchingAllFavorites = false
            guard let random = all.randomElement() else { return }
            searchFocused = false
            router.open(
                random,
                siblings: all,
                filters: filters,
                searchText: searchText,
                viewModel: viewModel
            )
        }
    }

    private var itemCountLabel: some View {
        Text(itemCountText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .inlineChrome(Capsule())
            .accessibilityLabel("\(itemCountText) dans les favoris")
    }

    private var busyIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(busyMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.75), in: Capsule())
        .padding(.bottom, DS.floatingPillInset)
        .transition(.opacity)
    }

    private var busyMessage: String {
        if deleteBusy { return "Suppression…" }
        if moveBusy { return "Déplacement…" }
        return ""
    }

    private func toggleSelection(_ file: DriveFile) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    private func toggleAll() {
        let loadedIDs = visibleSelectionIDs
        guard !loadedIDs.isEmpty else { return }
        if allSelected {
            selectedIDs.subtract(loadedIDs)
        } else {
            selectedIDs.formUnion(loadedIDs)
        }
    }

    private func startSelection() {
        searchFocused = false
        searchRevealed = false
        selectionMode = true
    }

    private func endSelection() {
        selectionMode = false
        selectedIDs.removeAll()
    }

    private func prepareMove(files: [DriveFile]) {
        guard !files.isEmpty else { return }
        pendingMove = MoveRequest(files: files)
    }

    private func prepareSelectedMove() {
        let files = visibleSelectionItems.filter { selectedIDs.contains($0.id) }
        prepareMove(files: files)
    }

    private func prepareTagSheet() {
        let files = visibleSelectionItems.filter { selectedIDs.contains($0.id) }
        guard !files.isEmpty else { return }
        pendingTags = TagRequest(files: files)
    }

    private func updateVisibleSelectionItems(_ items: [DriveFile], context: VisibleItemsContext) {
        guard context == currentVisibleItemsContext else { return }
        visibleItemsReport = VisibleItemsReport(context: context, items: items)
        if selectionMode {
            selectedIDs.formIntersection(Set(items.map(\.id)))
        }
    }

    private func unavailableDestinationIDs(for files: [DriveFile]) -> Set<Int> {
        guard files.allSatisfy({ $0.parentId != nil }) else { return [] }
        let parentIDs = Set(files.compactMap(\.parentId))
        return parentIDs.count == 1 ? parentIDs : []
    }

    private func move(_ files: [DriveFile], to destination: DriveFile) async {
        let ids = Set(files.map(\.id))
        guard !ids.isEmpty else { return }

        moveBusy = true
        let movedIDs = await viewModel.move(ids: ids, to: destination.id)

        if !movedIDs.isEmpty {
            let needsReload = viewModel.apply(.moved(
                driveId: viewModel.driveId, fileIds: movedIDs, destinationDirectoryId: destination.id
            ))
            if needsReload { await viewModel.reload(forceNetwork: true) }
        }

        selectedIDs.subtract(movedIDs)
        moveBusy = false

        if selectedIDs.isEmpty {
            selectionMode = false
        }
    }

    private func deleteSelected() async {
        let ids = actionableSelectedIDs
        guard !ids.isEmpty else { return }

        deleteBusy = true
        let deletedIDs = await viewModel.trash(ids: ids)

        selectedIDs.subtract(deletedIDs)
        selectedIDs.formIntersection(visibleSelectionIDs)
        deleteBusy = false

        if selectedIDs.isEmpty {
            selectionMode = false
        }
    }

    private func refreshAfterTags(_ changes: [TagChange]) async {
        let library = CategoryLibrary.shared.categories(for: viewModel.driveId)
        for change in changes {
            guard let category = library[change.categoryId] else { continue }
            let mutation = FileGridMutation.category(
                driveId: viewModel.driveId,
                fileId: change.file.id,
                category: category,
                applied: change.isAdd
            )
            viewModel.apply(mutation)
            FileGridMutationCenter.shared.publish(mutation)
        }
    }
}
