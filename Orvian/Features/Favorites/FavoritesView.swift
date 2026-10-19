import SwiftUI

struct FavoritesView: View {
    @Environment(\.iPadLayout) private var iPadLayout
    @Environment(\.phoneBottomChromeHeight) private var phoneBottomChromeHeight
    @State private var bottomControlsHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var mutationCredentialFingerprint = TokenStore.credentialFingerprint()
    @State private var viewModel: FileGridViewModel
    @State private var filters = FileFilters()
    private let router: ViewerRouter
    @Binding var path: [DriveFile]
    let scrollToTopRequest: Int
    private let title: String
    private let ownsNavigation: Bool
    private let onOpenFolder: ((DriveFile) -> Void)?
    @AppStorage("foldersFirstInTags") private var foldersFirstInTags = true

    @State private var searchText = ""
    @State private var searchDismissed = false
    @State private var searchRevealed = false
    @FocusState private var searchFocused: Bool
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false

    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var pendingMove: MoveRequest?
    @State private var pendingTags: TagRequest?
    @State private var moveBusy = false
    @State private var deleteBusy = false
    @State private var showDeleteConfirm = false

    init(
        driveId: Int,
        router: ViewerRouter,
        path: Binding<[DriveFile]>,
        scrollToTopRequest: Int = 0,
        source: FileSource = .favorites,
        title: String = "Favoris",
        ownsNavigation: Bool = true,
        onOpenFolder: ((DriveFile) -> Void)? = nil
    ) {
        self.router = router
        self._path = path
        self.scrollToTopRequest = scrollToTopRequest
        self.title = title
        self.ownsNavigation = ownsNavigation
        self.onOpenFolder = onOpenFolder
        _viewModel = State(initialValue: FileGridViewModel(source: source, driveId: driveId))
    }

    private struct MoveRequest: Identifiable {
        let id = UUID()
        let files: [DriveFile]
    }

    private struct TagRequest: Identifiable {
        let id = UUID()
        let files: [DriveFile]
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchBarVisible: Bool {
        isSearching || (!searchDismissed && (alwaysShowSearch || searchFocused || searchRevealed))
    }

    private var visibleSelectionItems: [DriveFile] {
        let isTag: Bool
        switch viewModel.source { case .category, .intersection: isTag = true; default: isTag = false }
        return viewModel.visibleSnapshot(filters: filters, searchText: searchText, foldersFirst: isTag && foldersFirstInTags).items
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
        visibleSelectionItems.count
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
        if viewModel.hasMore && viewModel.totalItemCount == nil {
            return "\(count) éléments chargés"
        }
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
        // Le rapport est invalidé dès que la recherche ou les filtres changent.
        visibleSelectionItems.filter { !$0.isDirectory }
    }



    var body: some View {
        Group {
            if ownsNavigation {
                NavigationStack(path: $path) {
                    browser.navigationDestination(for: DriveFile.self) { folderDestination($0) }
                }
                .transaction { $0.disablesAnimations = true }
            } else { browser }
        }
    }

    private var browser: some View {
            FileGridView(
                viewModel: viewModel,
                onOpenDirectory: { folder in
                    searchFocused = false
                    if let onOpenFolder { onOpenFolder(folder) } else { path.append(folder) }
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
                onResetFilters: { searchText = ""; filters = FileFilters() },
                onBackgroundTap: searchBarVisible ? dismissSearch : nil,
                searchText: searchText,
                filters: filters,
                contentBottomInset: bottomControlsHeight,
                allowsPullToRefresh: true,
                selectionMode: selectionMode,
                selectedIDs: selectedIDs,
                onToggleSelection: { toggleSelection($0) },
                onMove: { prepareMove(files: [$0]) },
                scrollToTopRequest: scrollToTopRequest
            )
            .id(viewModel.source)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(FileBrowserHeader(isVisible: !selectionMode, searchPresented: !selectionMode && searchBarVisible, search: { searchBar }) {
                if !selectionMode {
                    HStack(spacing: 6) {
                        if iPadLayout.isPad {
                            Text(title).lineLimit(1).truncationMode(.middle)
                                .font(.caption.weight(.medium))
                        }
                        itemCountLabel
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 16)
                }
            })
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
                        SelectionActionLayout {
                        Button {
                            toggleAll()
                        } label: {
                            Label(allSelected ? "Tout désélectionner" : "Sélectionner les fichiers affichés", systemImage: "checkmark.circle")
                        }
                        .accessibilityLabel(allSelected ? "Tout désélectionner" : "Sélectionner les fichiers affichés")

                        Button {
                            prepareTagSheet()
                        } label: {
                            Label("Appliquer des tags", systemImage: "tag")
                        }
                        .disabled(actionableSelectedIDs.isEmpty)
                        .accessibilityLabel("Mettre des tags")

                        Button {
                            prepareSelectedMove()
                        } label: {
                            Label("Déplacer", systemImage: "folder")
                        }
                        .disabled(actionableSelectedIDs.isEmpty || moveBusy)
                        .accessibilityLabel("Déplacer")

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                        .disabled(actionableSelectedIDs.isEmpty || deleteBusy)
                        .accessibilityLabel("Supprimer")
                        }
                    }
                } else {
                    if iPadLayout.isPad {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            FilterMenu(filters: $filters)
                                .accessibilityIdentifier("browser.filter")
                            if iPadLayout.isPad { FilePresentationToggle() }
                            searchToggleButton
                                .accessibilityIdentifier("browser.search")
                        }
                    } else {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            FilterMenu(filters: $filters)
                                .accessibilityIdentifier("browser.filter")
                            searchToggleButton
                                .accessibilityIdentifier("browser.search")
                        }
                    }

                    if !iPadLayout.isPad {
                        ToolbarItem(placement: .principal) {
                            Text(title).font(.headline).lineLimit(1)
                        }
                    }

                    BrowserToolbar(canOpenRandom: !playableFiles.isEmpty,
                                   canSelect: !visibleSelectionItems.isEmpty && !moveBusy,
                                   onRandom: openRandomFile, onSelect: startSelection)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if iPadLayout.isPad && (moveBusy || deleteBusy) {
                    busyIndicator
                }
            }
            .overlay(alignment: .bottom) {
                if !iPadLayout.isPad {
                    VStack(spacing: 0) {
                        if moveBusy || deleteBusy {
                            busyIndicator
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        bottomControlsHeight = $0
                    }
                    .padding(.bottom, phoneBottomChromeHeight)
                    // Meme ancrage que l'onglet Accueil : au-dessus du chrome
                    // mesure, puis au-dessus de la home indicator.
                    .safeAreaPadding(.bottom, 0)
                }
            }
            .background {
                BrowserKeyboardCommands(isEditingText: searchFocused, canSelect: !visibleSelectionItems.isEmpty,
                    search: { searchDismissed = false; searchRevealed = true; searchFocused = true },
                    cancel: { if selectionMode { endSelection() }; searchFocused = false; searchRevealed = false },
                    selectAll: { if !selectionMode { startSelection() }; selectedIDs = visibleSelectionIDs })
            }
            .sheet(item: $pendingMove) { request in
                MoveDestinationPicker(
                    driveId: viewModel.driveId,
                    itemCount: request.files.count,
                    excludedDirectoryIDs: Set(request.files.filter(\.isDirectory).map(\.id)),
                    unavailableDestinationIDs: unavailableDestinationIDs(for: request.files),
                    files: request.files, initialDirectory: nil,
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
                updateIntersectionSearch()
            }
            .onChange(of: filters) { _, _ in if selectionMode { endSelection() } }
            .onChange(of: viewModel.itemsRevision) { _, _ in selectedIDs.formIntersection(visibleSelectionIDs) }
            .onDisappear { searchFocused = false }
    }

    private func updateIntersectionSearch() {
        guard case let .intersection(selection) = viewModel.source else { return }
        let next = TagIntersection(Set(selection.ids), query: searchText)
        guard next != selection else { return }
        let model = FileGridViewModel(source: .intersection(next), driveId: viewModel.driveId)
        model.applySort(filters)
        viewModel = model
    }

    private func folderDestination(_ directory: DriveFile) -> some View {
                let index = path.firstIndex(where: { $0.id == directory.id })
                let crumbs = ["Favoris"] + (index.map { Array(path[...$0].map(\.name)) } ?? [])
                 return DirectoryView(
                    directory: directory,
                    driveId: viewModel.driveId,
                    crumbs: crumbs,
                    router: router,
                    onNavigateAncestor: { depth in path = Array(path.prefix(depth)) },
                    onOpenFolder: { folder in
                        path.append(folder)
                    }
                )
            }
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                "Rechercher dans \(title)…",
                text: $searchText
            )
            .focused($searchFocused)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityLabel("Rechercher dans \(title)")
            .frame(minHeight: 44)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .inputChrome(Capsule())
        .frame(maxWidth: horizontalSizeClass == .regular ? 600 : .infinity)
        .padding(.horizontal, DS.gridMargin)
    }

    private func dismissSearch() {
        searchFocused = false
        searchRevealed = false
        searchDismissed = true
    }

    private var searchToggleButton: some View {
        Button {
            if searchBarVisible && (!isSearching || searchFocused) {
                dismissSearch()
            } else {
                searchDismissed = false
                searchRevealed = true
                DispatchQueue.main.async { searchFocused = true }
            }
        } label: {
            Image(systemName: searchBarVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
        }
        .accessibilityLabel(isSearching ? (searchFocused ? "Masquer le clavier" : "Modifier la recherche") : (searchBarVisible ? "Fermer la recherche" : "Ouvrir la recherche"))
        .accessibilityHint("Une recherche active reste visible jusqu’à son effacement")
    }

    private func openRandomFile() {
        guard let random = playableFiles.randomElement() else { return }
        searchFocused = false
        router.open(
            random,
            siblings: playableFiles,
            filters: filters,
            searchText: searchText,
            viewModel: viewModel
        )
    }

    private var itemCountLabel: some View {
        Group {
            if iPadLayout.isPad {
                Text(itemCountText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3.5)
                    .inlineChrome(Capsule())
            } else {
                Text(itemCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(itemCountText) dans \(title)")
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
        .padding(.vertical, 8)
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
            FileGridMutationCenter.shared.publish(mutation, credentialFingerprint: mutationCredentialFingerprint
        )
        }
    }
}
