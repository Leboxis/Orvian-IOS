import SwiftUI

/// Contenu d'un dossier, avec breadcrumb compact.
/// Réutilisé par Accueil, Favoris et Tag (chaque onglet possède sa pile).
struct DirectoryView: View {
    let directory: DriveFile
    let driveId: Int
    let crumbs: [String]
    /// Affiche la barre de recherche (onglet Accueil uniquement).
    let showsSearchBar: Bool
    /// Retire le focus du champ quand son onglet n'est plus affiché.
    let isActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.iPadLayout) private var iPadLayout
    @Environment(\.phoneBottomChromeHeight) private var phoneBottomChromeHeight
    @State private var bottomControlsHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isActiveTab) private var isActiveTab
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.canImportFiles) private var canImportFiles
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var mutationCredentialFingerprint = TokenStore.credentialFingerprint()
    @State private var viewModel: FileGridViewModel
    @State private var searchViewModel: FileGridViewModel?
    @State private var addBusy = false
    @State private var busyMessage = ""
    @State private var addError: String?
    @State private var searchText = ""
    /// Requête possédée actuellement par `searchViewModel` : évite d'afficher
    /// les résultats d'une recherche précédente pendant le debounce ou le
    /// chargement d'une requête plus récente (y compris après un changement
    /// de portée).
    @State private var searchQuery = ""
    /// Vrai une fois le rechargement du `searchViewModel` courant terminé.
    /// Une task redémarrée après un aller-retour de navigation ne réutilise
    /// les résultats existants que s'ils sont complets.
    @State private var searchResultsReady = false
    /// La barre de recherche n'est plus pilotée par le scroll : seul le
    /// bouton loupe (et le focus / une recherche active) la révèle.
    @State private var searchDismissed = false
    @State private var searchRevealed = false
    @State private var filters = FileFilters()

    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @AppStorage("foldersFirstInTags") private var foldersFirstInTags = true
    @State private var pendingMove: MoveRequest?
    @State private var pendingTags: TagRequest?
    @State private var moveBusy = false
    @State private var deleteBusy = false
    @State private var showDeleteConfirm = false
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false
    @AppStorage("showBreadcrumb") private var showBreadcrumb = true
    /// Recherche limitée au dossier courant et à tous ses sous-dossiers ;
    /// désactivée, elle couvre tout le drive.
    @AppStorage("searchRestrictedToFolder") private var searchRestrictedToFolder = false
    @FocusState private var searchFocused: Bool
    @State private var showImportPicker = false
    /// Onglet dont ce dossier mémorise le tri et les filtres. Les dossiers
    /// ouverts depuis les Favoris ou les Tags gardent leur propre réglage.
    private let filtersScope: FileBrowserScope

    private let router: ViewerRouter
    private let onOpenFolder: (DriveFile) -> Void
    private let onNavigateAncestor: ((Int) -> Void)?

    /// Fige la sélection au moment où le sélecteur de destination s'ouvre.
    /// La feuille peut ainsi naviguer sans dépendre d'un état de sélection qui
    /// changerait pendant sa présentation.
    private struct MoveRequest: Identifiable {
        let id = UUID()
        let files: [DriveFile]
    }

    /// Fige la sélection au moment où la feuille de tags s'ouvre.
    private struct TagRequest: Identifiable {
        let id = UUID()
        let files: [DriveFile]
    }

    /// Associe le callback de la grille aux données qui l'ont produit. Un
    /// callback tardif d'une recherche ou d'un filtre précédent ne peut ainsi
    /// ni fausser le compteur ni modifier la sélection courante.
    init(
        directory: DriveFile,
        driveId: Int,
        crumbs: [String],
        router: ViewerRouter,
        isActive: Bool = true,
        showsSearchBar: Bool = true,
        filtersScope: FileBrowserScope = .home,
        onNavigateAncestor: ((Int) -> Void)? = nil,
        onOpenFolder: @escaping (DriveFile) -> Void
    ) {
        self.directory = directory
        self.driveId = driveId
        self.crumbs = crumbs
        self.router = router
        self.isActive = isActive
        self.showsSearchBar = showsSearchBar
        self.filtersScope = filtersScope
        self.onOpenFolder = onOpenFolder
        self.onNavigateAncestor = onNavigateAncestor
        let model = FileGridViewModel(source: .directory(directory.id), driveId: driveId)
        let restored = FileFiltersStore.load(scope: filtersScope)
        // Le tri restauré doit être connu du vue-modèle avant le premier
        // chargement : sinon le serveur renvoie l'ordre d'origine alors que
        // le menu affiche déjà le tri mémorisé.
        model.applySort(restored)
        _filters = State(initialValue: restored)
        _viewModel = State(initialValue: model)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeViewModel: FileGridViewModel {
        if let searchViewModel,
           searchQuery == searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
            return searchViewModel
        }
        return viewModel
    }

    private var visibleSelectionItems: [DriveFile] {
        activeViewModel.visibleSnapshot(filters: filters, searchText: searchText, foldersFirst: false).items
    }

    var body: some View {
        FileGridView(
            viewModel: activeViewModel,
            onOpenDirectory: { folder in
                // La vue reste montée dans le NavigationStack : sans ce
                // retrait explicite, le clavier suit jusqu'à l'écran poussé.
                searchFocused = false
                onOpenFolder(folder)
            },
            onOpenFile: { file, siblings in
                searchFocused = false
                router.open(
                    file,
                    siblings: siblings,
                    filters: filters,
                    searchText: searchText,
                    viewModel: activeViewModel
                )
            },
            onResetFilters: { searchText = ""; filters = FileFilters() },
            onEmptyAction: { showImportPicker = true },
            onBackgroundTap: searchBarPresented ? dismissSearch : nil,
            searchText: searchText,
            filters: filters,
            contentBottomInset: bottomControlsHeight,
            allowsPullToRefresh: true,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onToggleSelection: { toggleSelection($0) },
            onMove: { prepareMove(files: [$0]) }
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(FileDropTarget(
            isEnabled: isEnabled && isActive && isActiveTab && !selectionMode && !addBusy && !moveBusy,
            onFiles: { urls in
                guard canImportFiles(driveId),
                      mutationCredentialFingerprint != nil,
                      mutationCredentialFingerprint == TokenStore.credentialFingerprint() else {
                    Task.detached { DroppedFileStaging.remove(urls) }
                    return
                }
                UploadManager.shared.enqueueDocuments(driveId: driveId, directoryId: directory.id,
                    urls: urls) { files in
                    Task { await refreshAfterImport(files) }
                }
            },
            onError: { addError = $0 }
        ))
        .modifier(FileBrowserHeader(isVisible: !selectionMode, searchPresented: !selectionMode && searchBarPresented, search: { searchBar }) {
            if !selectionMode {
                HStack(spacing: 6) {
                    if showBreadcrumb {
                        breadcrumb
                    } else {
                        Text(directory.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if !activeViewModel.isInitialLoading {
                        itemCountLabel
                            .fixedSize(horizontal: true, vertical: false)
                    }
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
                        if showsSearchBar {
                            searchToggleButton
                                .accessibilityIdentifier("browser.search")
                        }
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        FilterMenu(filters: $filters)
                            .accessibilityIdentifier("browser.filter")
                        if showsSearchBar {
                            searchToggleButton
                                .accessibilityIdentifier("browser.search")
                        }
                    }
                }

                if iPadLayout.isPad {
                    ToolbarItem(placement: .topBarLeading) {
                        addMenu
                            .accessibilityLabel("Ajouter ou importer")
                    }
                }
                BrowserToolbar(canOpenRandom: !playableFiles.isEmpty,
                               canSelect: !visibleSelectionItems.isEmpty && !moveBusy && !addBusy,
                               onRandom: openRandomFile, onSelect: startSelection)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if iPadLayout.isPad && (addBusy || moveBusy || deleteBusy) {
                busyIndicator
            }
        }
        .overlay(alignment: .bottom) {
            if !iPadLayout.isPad {
                VStack(spacing: 0) {
                    if addBusy || moveBusy || deleteBusy {
                        busyIndicator
                    }
                    if !selectionMode {
                        HStack {
                            Spacer()
                            addMenu
                                .frame(width: 52, height: 52)
                                .floatingChrome(Circle())
                                .accessibilityLabel("Ajouter ou importer")
                        }
                        .padding(.trailing, DS.gridMargin + 4)
                        .padding(.bottom, DS.contentBottomInset)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    bottomControlsHeight = $0
                }
                .padding(.bottom, phoneBottomChromeHeight)
            }
        }
        .background {
            BrowserKeyboardCommands(isEditingText: searchFocused, canSelect: !visibleSelectionItems.isEmpty,
                search: { searchDismissed = false; searchRevealed = true; searchFocused = true },
                cancel: { if selectionMode { endSelection() }; searchFocused = false; searchRevealed = false },
                selectAll: { if !selectionMode { startSelection() }; selectedIDs = Set(visibleSelectionItems.map(\.id)) })
                .disabled(!isActive)
        }
        .sheet(isPresented: $showImportPicker) {
            DocumentPicker { urls in
                UploadManager.shared.enqueueDocuments(driveId: driveId, directoryId: directory.id, urls: urls) { files in
                    Task { await refreshAfterImport(files) }
                }
            }
        }
        .alert("Impossible", isPresented: addErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
        .sheet(item: $pendingMove) { request in
            MoveDestinationPicker(
                driveId: driveId,
                itemCount: request.files.count,
                excludedDirectoryIDs: Set(request.files.filter(\.isDirectory).map(\.id)),
                unavailableDestinationIDs: unavailableDestinationIDs(for: request.files),
                files: request.files, initialDirectory: isSearching ? nil : directory,
                onSelect: { destination in
                    pendingMove = nil
                    Task { await move(request.files, to: destination) }
                }
            )
        }
        .sheet(item: $pendingTags) { request in
            ApplyTagsSheet(
                driveId: driveId,
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
        .onChange(of: filters) { _, newFilters in
            FileFiltersStore.save(newFilters, scope: filtersScope)
            if selectionMode { endSelection() }
        }
        .onChange(of: activeViewModel.itemsRevision) { _, _ in selectedIDs.formIntersection(Set(visibleSelectionItems.map(\.id))) }
        .onChange(of: isActive) { _, active in
            if !active {
                searchFocused = false
            }
        }
        .task(id: DirectoryActivationKey(isActive: isActive, phase: scenePhase)) {
            guard isActive, scenePhase == .active else { return }
            // Le tri et les filtres sont mémorisés par onglet : le vue-modèle
            // neuf doit partir du tri restauré, sinon l'écran affichait le tri
            // choisi mais recevait la liste dans l'ordre d'origine.
            viewModel.applySort(filters)
            await viewModel.loadIfNeeded()
        }
        .task(id: SearchTaskKey(query: searchText, restricted: searchRestrictedToFolder)) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Le tri a pu changer pendant la recherche : la grille ne
                // recharge que le vue-modèle qu'elle affiche, jamais celui du
                // dossier. Le resynchroniser ici évite qu'il reparte de son
                // ancien ordre alors que le menu affiche encore le tri choisi.
                await viewModel.syncSort(with: filters)
                searchViewModel = nil
                searchQuery = ""
                searchResultsReady = false
                return
            }
            let source = FileSource.search(
                query: trimmed,
                // Restreint au dossier courant et à toute sa descendance ;
                // sinon la recherche porte sur tout le drive.
                directoryId: searchRestrictedToFolder ? directory.id : nil
            )
            // La task redémarre à l'identique au retour arrière (elle avait été
            // annulée quand l'écran a été couvert) : réutiliser les résultats
            // déjà chargés évite un squelette et un saut de scroll.
            if let existing = searchViewModel,
               searchQuery == trimmed,
               existing.source == source,
               searchResultsReady {
                return
            }
            // Debounce de 300 ms pour éviter les requêtes superflues pendant la saisie
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            let searchVM = FileGridViewModel(source: source, driveId: driveId)
            // Le tri de l'écran s'applique aussi à la recherche : sans lui,
            // le vue-modèle neuf repart de l'ordre d'origine et les résultats
            // arrivent dans l'ordre de pertinence, quel que soit le tri affiché.
            searchVM.applySort(filters)
            searchQuery = trimmed
            searchViewModel = searchVM
            searchResultsReady = false
            await searchVM.reload()
            searchResultsReady = !Task.isCancelled
        }
    }

    /// La barre apparaît sur demande (bouton loupe) ou lorsque la recherche est active.
    private var searchBarVisible: Bool {
        isSearching || (!searchDismissed && (alwaysShowSearch || searchFocused || searchRevealed))
    }

    /// Applique les effets de disposition uniquement aux écrans qui possèdent
    /// réellement une barre de recherche.
    private var searchBarPresented: Bool {
        showsSearchBar && searchBarVisible
    }

    /// Clé du task de recherche : le texte ET la portée. Basculer la
    /// restriction relance donc la requête en cours sans attendre une saisie.
    private struct SearchTaskKey: Hashable {
        let query: String
        let restricted: Bool
    }

    private struct DirectoryActivationKey: Equatable {
        let isActive: Bool
        let phase: ScenePhase
    }

    /// Pastille de recherche centrée et compacte.
    private var searchBar: some View {
        VStack(spacing: 2) {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                searchRestrictedToFolder ? "Rechercher dans ce dossier…" : "Rechercher dans tout le drive…",
                text: $searchText
            )
            .focused($searchFocused)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityLabel("Rechercher des fichiers")
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
            if !dynamicTypeSize.isAccessibilitySize || iPadLayout.isPad { searchScopeButton }
        }
        if dynamicTypeSize.isAccessibilitySize && !iPadLayout.isPad { searchScopeButton }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .inputChrome(RoundedRectangle(cornerRadius: DS.panelRadius))
        .frame(maxWidth: horizontalSizeClass == .regular ? 600 : .infinity)
        .padding(.horizontal, DS.gridMargin)
    }

    /// Bascule la portée : dossier courant + sous-dossiers, ou tout le drive.
    private var searchScopeButton: some View {
        Menu {
            Button("Ce dossier et ses sous-dossiers") { searchRestrictedToFolder = true }
            Button("Tout le drive") { searchRestrictedToFolder = false }
        } label: {
            Label(searchRestrictedToFolder ? "Ce dossier" : "Tout le drive", systemImage: "chevron.down")
                .font(.caption)
                .foregroundStyle(searchRestrictedToFolder ? Color.accentColor : .secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchRestrictedToFolder
            ? "Recherche limitée au dossier et ses sous-dossiers"
            : "Recherche sur tout le drive")
        .accessibilityHint("Limite la recherche au dossier actuel et à tous ses sous-dossiers.")
        .accessibilityAddTraits(searchRestrictedToFolder ? [.isSelected] : [])
    }

    /// Masque le clavier, mais garde toute requête active visible et effaçable.
    private func dismissSearch() {
        searchFocused = false
        searchRevealed = false
        searchDismissed = true
    }

    private var searchToggleButton: some View {
        Button {
            if searchBarPresented && (!isSearching || searchFocused) {
                dismissSearch()
            } else {
                searchDismissed = false
                searchRevealed = true
                DispatchQueue.main.async { searchFocused = true }
            }
        } label: {
            Image(systemName: searchBarPresented ? "magnifyingglass.circle.fill" : "magnifyingglass")
        }
        .accessibilityLabel(isSearching ? (searchFocused ? "Masquer le clavier" : "Modifier la recherche") : (searchBarPresented ? "Fermer la recherche" : "Ouvrir la recherche"))
        .accessibilityHint("Une recherche active reste visible jusqu’à son effacement")
    }

    /// Bouton dé : ouvre au hasard un fichier parmi les cartes visibles.
    private var playableFiles: [DriveFile] {
        // Même population que les cartes visibles, jamais la liste brute.
        visibleSelectionItems.filter { !$0.isDirectory }
    }

    private func openRandomFile() {
        guard let random = playableFiles.randomElement() else { return }
        searchFocused = false
        router.open(
            random,
            siblings: playableFiles,
            filters: filters,
            searchText: searchText,
            viewModel: activeViewModel
        )
    }

    private var allSelected: Bool {
        !visibleSelectionIDs.isEmpty && selectedIDs.isSuperset(of: visibleSelectionIDs)
    }

    private var visibleSelectionIDs: Set<Int> {
        Set(visibleSelectionItems.map(\.id))
    }

    private var actionableSelectedIDs: Set<Int> {
        selectedIDs.intersection(visibleSelectionIDs)
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

    private var selectionTitle: String {
        let count = actionableSelectedIDs.count
        guard count > 0 else { return "Sélection" }
        return "\(count) sélectionné\(count > 1 ? "s" : "")"
    }

    private func startSelection() {
        searchFocused = false
        // La révélation manuelle est consommée : sans cette remise à zéro,
        // quitter la sélection ferait ressusciter la barre sans action.
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

    private func deleteSelected() async {
        let ids = actionableSelectedIDs
        guard !ids.isEmpty else { return }

        deleteBusy = true
        busyMessage = "Suppression de \(ids.count) élément\(ids.count > 1 ? "s" : "")…"
        let deletingViewModel = activeViewModel
        let deletedIDs = await deletingViewModel.trash(ids: ids)

        // La diffusion `.removal` couvre les grilles à l'écoute ; quand la
        // suppression part de la recherche, la vue du dossier n'écoute pas
        // pendant ce temps : la mutation lui est appliquée directement pour
        // que son retour à l'écran n'affiche pas de carte disparue.
        if !deletedIDs.isEmpty, deletingViewModel !== viewModel {
            viewModel.apply(FileGridMutation.removal(driveId: driveId, fileIds: deletedIDs))
        }

        selectedIDs.subtract(deletedIDs)
        selectedIDs.formIntersection(visibleSelectionIDs)
        deleteBusy = false

        // L'échec éventuel est signalé par l'alerte de FileGridView
        // (mutationErrorMessage du même view model que la grille affiche).
        if selectedIDs.isEmpty {
            selectionMode = false
        }
    }

    /// Après application des tags : les modifications confirmées par l'API
    /// arrivent de la feuille et sont diffusées aux grilles (dossier courant,
    /// recherche) — pastilles à jour sans rechargement réseau ni saut de
    /// scroll.
    private func refreshAfterTags(_ changes: [TagChange]) async {
        let library = CategoryLibrary.shared.categories(for: driveId)
        for change in changes {
            guard let category = library[change.categoryId] else { continue }
            let mutation = FileGridMutation.category(
                driveId: driveId,
                fileId: change.file.id,
                category: category,
                applied: change.isAdd
            )
            // Quand la feuille a été ouverte depuis la recherche, la vue du
            // dossier n'écoute pas la diffusion pendant ce temps : la
            // mutation lui est appliquée directement.
            if activeViewModel !== viewModel {
                viewModel.apply(mutation)
            }
            FileGridMutationCenter.shared.publish(mutation, credentialFingerprint: mutationCredentialFingerprint
        )
        }
    }

    /// Le dossier parent commun est désactivé : y déplacer tous les éléments
    /// ne produirait aucun changement.
    private func unavailableDestinationIDs(for files: [DriveFile]) -> Set<Int> {
        guard files.allSatisfy({ $0.parentId != nil }) else { return [] }
        let parentIDs = Set(files.compactMap(\.parentId))
        return parentIDs.count == 1 ? parentIDs : []
    }

    private func move(_ files: [DriveFile], to destination: DriveFile) async {
        let ids = Set(files.map(\.id))
        guard !ids.isEmpty else { return }

        moveBusy = true
        busyMessage = "Déplacement de \(ids.count) élément\(ids.count > 1 ? "s" : "")…"
        let movingViewModel = activeViewModel
        let movedIDs = await movingViewModel.move(ids: ids, to: destination.id)

        // La diffusion `.moved` couvre les grilles à l'écoute ; quand le
        // déplacement part de la recherche, la vue du dossier n'écoute pas
        // pendant ce temps : la mutation lui est appliquée directement.
        if !movedIDs.isEmpty, movingViewModel !== viewModel {
            let needsReload = viewModel.apply(.moved(
                driveId: driveId, fileIds: movedIDs, destinationDirectoryId: destination.id
            ))
            if needsReload { await viewModel.reload(forceNetwork: true) }
        }

        selectedIDs.subtract(movedIDs)
        moveBusy = false

        // L'échec éventuel est signalé par l'alerte de FileGridView
        // (mutationErrorMessage du view model utilisé pour le déplacement,
        // grille courante ou résultats de recherche).
        if selectedIDs.isEmpty {
            selectionMode = false
        }
    }

    private var addErrorBinding: Binding<Bool> {
        Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )
    }

    /// Pastille de progression pendant un import / une création.
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

    private var addMenu: some View {
        AddMenuButton(
            directoryId: directory.id,
            driveId: driveId,
            isBusy: $addBusy,
            busyMessage: $busyMessage,
            errorMessage: $addError,
            onFolderCreated: {
                Task { await refreshAfterFolderCreation() }
            },
            onDone: { uploadedFiles in
                Task { await refreshAfterImport(uploadedFiles) }
            }
        )
    }

    /// Affichage immédiat : les fichiers confirmés par l'API entrent dans la
    /// grille (tri courant respecté, compteur recalé par `mergeUploaded`)
    /// sans attendre le moindre aller-retour. La recherche, si elle est
    /// affichée, est revalidée en arrière-plan : c'est le serveur qui décide
    /// de l'appartenance au résultat.
    private func refreshAfterImport(_ uploadedFiles: [DriveFile]) async {
        guard !uploadedFiles.isEmpty else { return }
        viewModel.mergeUploaded(uploadedFiles)
        if isSearching {
            await searchViewModel?.reload()
        }
    }

    /// La création ne renvoie pas le nouveau dossier : seule une relecture
    /// réseau forcée peut confirmer et afficher la liste mise à jour.
    private func refreshAfterFolderCreation() async {
        await viewModel.reload(forceNetwork: true)
        if isSearching {
            await searchViewModel?.reload(forceNetwork: true)
        }
    }

    /// Bulle compacte indiquant le chemin du dossier (4 derniers niveaux max).
    private var displayedCrumbs: [String] {
        Array(crumbs.suffix(4))
    }

    private var isBreadcrumbTruncated: Bool {
        crumbs.count > displayedCrumbs.count
    }

    private var breadcrumb: some View {
        Group {
            if let onNavigateAncestor, crumbs.count > 1 {
                let menu = Menu {
                    ForEach(Array(crumbs.dropLast().enumerated()), id: \.offset) { index, name in
                        Button(name) { searchFocused = false; onNavigateAncestor(index) }
                    }
                } label: {
                    breadcrumbLabel
                        .frame(minHeight: iPadLayout.isPad ? 22 : 44)
                }
                .accessibilityHint("Revenir à un dossier parent")

                if iPadLayout.isPad {
                    menu
                } else {
                    menu
                        .buttonStyle(.plain)
                        .tint(.primary)
                        .menuIndicator(.hidden)
                }
            } else {
                breadcrumbLabel
            }
        }
    }

    private var breadcrumbLabel: some View {
        Group {
            if iPadLayout.isPad {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text((isBreadcrumbTruncated ? "…  ›  " : "") + displayedCrumbs.joined(separator: "  ›  "))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .inlineChrome(Capsule())
            } else {
                HStack(spacing: 5) {
                    Text(directory.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .truncationMode(.middle)
                    if onNavigateAncestor != nil && crumbs.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityAddTraits(.isHeader)
            }
        }
        .accessibilityLabel("Chemin : " + crumbs.joined(separator: ", "))
    }

    /// Sans filtre, le total serveur reste la quantité exacte du dossier. Avec
    /// une recherche ou un filtre local, le callback de la grille fournit le
    /// nombre réellement visible ; « partiel » signale les pages restantes.
    private var itemCountLabel: some View {
        let text = itemCountText
        return Group {
            if iPadLayout.isPad {
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3.5)
                    .inlineChrome(Capsule())
            } else {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(usesVisibleItemCount ? text : "\(text) dans ce dossier")
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

    private var reportedVisibleItemCount: Int? {
        visibleSelectionItems.count
    }

    private var displayedItemCount: Int? {
        guard activeViewModel.itemsRevision > 0, !activeViewModel.isInitialLoading else { return nil }
        if isSearching, case .search = activeViewModel.source, !searchResultsReady {
            return nil
        }
        if usesVisibleItemCount {
            return reportedVisibleItemCount
        }
        return activeViewModel.totalItemCount
            ?? reportedVisibleItemCount
            ?? activeViewModel.items.count
    }

    private var itemCountText: String {
        guard let count = displayedItemCount else {
            if isSearching { return "Recherche…" }
            return hasCountFiltering ? "Filtrage…" : "Chargement…"
        }
        let plural = count > 1
        if isSearching {
            let text = "\(count) résultat\(plural ? "s" : "")\(hasCountFiltering ? " visible\(plural ? "s" : "")" : "")"
            return displayedCountIsPartial ? text + " (partiel)" : text
        }
        if usesVisibleItemCount {
            let text = "\(count) élément\(plural ? "s" : "") visible\(plural ? "s" : "")"
            return displayedCountIsPartial ? text + " (partiel)" : text
        }
        let text = "\(count) élément\(plural ? "s" : "")"
        return displayedCountIsPartial ? text + " (partiel)" : text
    }

    private var displayedCountIsPartial: Bool {
        activeViewModel.hasMore
            && (usesVisibleItemCount || activeViewModel.totalItemCount == nil)
    }
}
