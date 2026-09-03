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
    @State private var scrolledPastTop = false
    @State private var filters = FileFilters()
    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var visibleSelectionItems: [DriveFile] = []
    @State private var pendingMove: MoveRequest?
    @State private var pendingTags: TagRequest?
    @State private var moveBusy = false
    @State private var deleteBusy = false
    @State private var showDeleteConfirm = false
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false
    /// Recherche limitée au dossier courant et à tous ses sous-dossiers ;
    /// désactivée, elle couvre tout le drive.
    @AppStorage("searchRestrictedToFolder") private var searchRestrictedToFolder = false
    @FocusState private var searchFocused: Bool

    private let router: ViewerRouter
    private let onOpenFolder: (DriveFile) -> Void

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

    init(
        directory: DriveFile,
        driveId: Int,
        crumbs: [String],
        router: ViewerRouter,
        isActive: Bool = true,
        showsSearchBar: Bool = false,
        onOpenFolder: @escaping (DriveFile) -> Void
    ) {
        self.directory = directory
        self.driveId = driveId
        self.crumbs = crumbs
        self.router = router
        self.isActive = isActive
        self.showsSearchBar = showsSearchBar
        self.onOpenFolder = onOpenFolder
        _viewModel = State(initialValue: FileGridViewModel(source: .directory(directory.id), driveId: driveId))
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
            onVisibleItemsChanged: updateVisibleSelectionItems,
            searchText: searchText,
            filters: filters,
            onScrolledPastTop: showsSearchBar ? { scrolledPastTop = $0 } : nil,
            allowsPullToRefresh: !showsSearchBar,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onToggleSelection: { toggleSelection($0) },
            onMove: { prepareMove(files: [$0]) }
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !selectionMode {
                VStack(spacing: 8) {
                    breadcrumb
                        .frame(maxWidth: .infinity)

                    if searchBarPresented {
                        VStack(spacing: 0) {
                            searchBar
                            itemCountLabel
                                .padding(.vertical, 10)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else if !showsSearchBar {
                        itemCountLabel
                            .padding(.vertical, 10)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, searchBarPresented ? 0 : 4)
                .animation(.snappy(duration: 0.25), value: searchBarPresented)
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
                ToolbarItem(placement: .topBarLeading) {
                    FilterMenu(filters: $filters)
                }

                ToolbarItem(placement: .principal) {
                    Text(crumbs.last ?? directory.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    randomFileButton

                    Button {
                        startSelection()
                    } label: {
                        Label("Sélectionner", systemImage: "checkmark.circle")
                    }
                    .disabled(visibleSelectionItems.isEmpty || moveBusy || addBusy)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if addBusy || moveBusy || deleteBusy {
                busyIndicator
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !selectionMode {
                floatingAddButton
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
                parentDirectory: directory.parentId == nil ? nil : directory,
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
        .onChange(of: isActive) { _, active in
            if !active {
                searchFocused = false
            }
        }
        .task(id: SearchTaskKey(query: searchText, restricted: searchRestrictedToFolder)) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
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
            searchQuery = trimmed
            searchViewModel = searchVM
            searchResultsReady = false
            await searchVM.reload()
            searchResultsReady = !Task.isCancelled
        }
    }

    /// La barre apparaît lors d'un défilé vers le haut ou lorsque la recherche est active.
    private var searchBarVisible: Bool {
        alwaysShowSearch || searchFocused || isSearching || scrolledPastTop
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

    /// Pastille de recherche centrée et compacte.
    private var searchBar: some View {
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
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Effacer la recherche")
            }
            searchScopeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(.bar, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
        .frame(maxWidth: 260)
    }

    /// Bascule la portée : dossier courant + sous-dossiers, ou tout le drive.
    private var searchScopeButton: some View {
        Button {
            searchRestrictedToFolder.toggle()
        } label: {
            Image(systemName: searchRestrictedToFolder ? "smallcircle.fill.circle.fill" : "smallcircle.filled.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(searchRestrictedToFolder ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // La zone tactile (30 pt) déborde de la ligne : la pastille conserve
        // la hauteur d'origine au lieu d'épouser celle du bouton.
        .padding(.vertical, -4)
        .accessibilityLabel(searchRestrictedToFolder
            ? "Recherche limitée au dossier et ses sous-dossiers"
            : "Recherche sur tout le drive")
        .accessibilityHint("Limite la recherche au dossier actuel et à tous ses sous-dossiers.")
        .accessibilityAddTraits(searchRestrictedToFolder ? [.isSelected] : [])
    }

    /// Bouton dé : ouvre au hasard un fichier parmi les éléments du dossier actuel.
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
        .disabled(playableFiles.isEmpty)
        .accessibilityLabel("Ouvrir un fichier au hasard")
    }

    private var playableFiles: [DriveFile] {
        activeViewModel.items.filter { !$0.isDirectory }
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
        // La révélation par scroll est consommée : sans cette remise à zéro,
        // quitter la sélection ferait ressusciter la barre sans action.
        scrolledPastTop = false
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

    private func updateVisibleSelectionItems(_ items: [DriveFile]) {
        visibleSelectionItems = items
        if selectionMode {
            selectedIDs.formIntersection(Set(items.map(\.id)))
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
            FileGridMutationCenter.shared.publish(mutation)
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

        // La diffusion `.removal` couvre les grilles à l'écoute ; quand le
        // déplacement part de la recherche, la vue du dossier n'écoute pas
        // pendant ce temps : la mutation lui est appliquée directement.
        if !movedIDs.isEmpty, movingViewModel !== viewModel {
            viewModel.apply(FileGridMutation.removal(driveId: driveId, fileIds: movedIDs))
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
        .padding(.bottom, 130)
        .transition(.opacity)
    }

    /// Action d'import séparée de la barre d'outils pour préserver la place
    /// du titre du dossier. La marge basse l'aligne au-dessus de la barre
    /// d'onglets flottante sans recouvrir la dernière rangée de cartes.
    private var floatingAddButton: some View {
        AddMenuButton(
            directoryId: directory.id,
            driveId: driveId,
            isBusy: $addBusy,
            busyMessage: $busyMessage,
            errorMessage: $addError,
            onDone: { uploadedFiles in
                Task { await refreshAfterImport(uploadedFiles) }
            }
        )
        .frame(width: 52, height: 52)
        .background(.ultraThinMaterial, in: Circle())
        .overlay {
            Circle().strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.trailing, DS.gridMargin + 4)
        .padding(.bottom, 104)
        .accessibilityLabel("Ajouter ou importer")
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

    /// Bulle compacte indiquant le chemin du dossier.
    private var breadcrumb: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .medium))
            Text(crumbs.joined(separator: "  ›  "))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 3.5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        .accessibilityLabel("Chemin : " + crumbs.joined(separator: ", "))
    }

    /// Le nombre d'éléments est volontairement séparé du fil d'Ariane et
    /// placé entre la recherche et le début de la grille. On préfère le total
    /// annoncé par le serveur (vraie quantité du dossier, même avant que la
    /// pagination ait tout chargé) et on retombe sur les éléments chargés
    /// lorsque l'API ne fournit pas de total.
    private var itemCountLabel: some View {
        let total = activeViewModel.totalItemCount
        let count = total ?? activeViewModel.items.count
        return Text("\(count) élément\(count > 1 ? "s" : "")")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            }
            .accessibilityLabel("\(count) élément\(count > 1 ? "s" : "") dans ce dossier")
    }
}
