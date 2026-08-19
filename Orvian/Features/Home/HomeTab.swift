import SwiftUI

/// Onglet « Accueil » : navigation dans l'arborescence du drive.
struct HomeTab: View {
    let driveId: Int
    let router: ViewerRouter
    @Binding var path: [DriveFile]

    /// Premier dossier du drive. Il devient la racine de navigation : la
    /// racine technique du drive n'est jamais ajoutée au NavigationStack et
    /// n'est donc pas accessible par retour.
    @State private var startDirectory: DriveFile?
    private let service = KDriveService()

    private var cacheKey: String { "home_start_dir_locked_\(driveId)" }
    private var previousCacheKey: String { "home_start_dir_\(driveId)" }

    init(driveId: Int, router: ViewerRouter, path: Binding<[DriveFile]>) {
        self.driveId = driveId
        self.router = router
        self._path = path

        if let data = UserDefaults.standard.data(forKey: "home_start_dir_locked_\(driveId)"),
           let cached = try? JSONDecoder().decode(DriveFile.self, from: data) {
            _startDirectory = State(initialValue: cached)
        }
    }

    @ViewBuilder
    var body: some View {
        if let startDirectory {
            navigationRoot(startDirectory)
        } else {
            ProgressView("Ouverture de l’Accueil…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: driveId) {
                    await resolveStartDirectory()
                }
        }
    }

    private func navigationRoot(_ root: DriveFile) -> some View {
        NavigationStack(path: $path) {
            DirectoryView(
                directory: root,
                driveId: driveId,
                crumbs: [root.name],
                router: router,
                showsSearchBar: true,
                onOpenFolder: { folder in
                    path.append(folder)
                }
            )
            .navigationDestination(for: DriveFile.self) { directory in
                let index = path.firstIndex(where: { $0.id == directory.id })
                let crumbs = [root.name] + (index.map { Array(path[...$0].map(\.name)) } ?? [directory.name])
                DirectoryView(
                    directory: directory,
                    driveId: driveId,
                    crumbs: crumbs,
                    router: router,
                    showsSearchBar: true,
                    onOpenFolder: { folder in
                        path.append(folder)
                    }
                )
            }
        }
    }

    /// Résout le premier dossier du drive. L'ancien cache contient déjà ce
    /// dossier ; sans cache, une seule lecture de la racine technique suffit.
    private func resolveStartDirectory() async {
        let defaults = UserDefaults.standard
        var resolved: DriveFile?

        if let data = defaults.data(forKey: previousCacheKey),
           let cached = try? JSONDecoder().decode(DriveFile.self, from: data) {
            resolved = cached
        }

        if resolved == nil,
           let page = try? await service.page(.directory(1), driveId: driveId, cursor: nil) {
            resolved = page.data?.first(where: \.isDirectory)
        }

        guard !Task.isCancelled else { return }
        guard let resolved else {
            // Sans cache ni réseau, conserver un Accueil utilisable pour cette
            // session seulement. La résolution sera retentée au prochain départ.
            path.removeAll()
            startDirectory = DriveFile.root(name: "Accueil")
            return
        }

        path.removeAll()
        startDirectory = resolved

        if let data = try? JSONEncoder().encode(resolved) {
            defaults.set(data, forKey: cacheKey)
        }

        // L'ancien cache n+1 pointait un niveau trop bas et ne doit plus être
        // repris par une future version.
        defaults.removeObject(forKey: "home_start_dir_n_plus_1_\(driveId)")
    }
}

extension DriveFile {
    /// Racine du drive (id 1).
    static func root(name: String) -> DriveFile {
        DriveFile(
            id: 1,
            name: name,
            type: "dir",
            size: nil,
            mimeType: nil,
            extensionType: nil,
            isFavorite: nil,
            parentId: nil,
            path: nil,
            color: nil,
            categories: nil,
            addedAt: nil,
            lastModifiedAt: nil
        )
    }
}

/// Contenu d'un dossier, avec breadcrumb compact.
/// Réutilisé par Accueil, Favoris et Tag (chaque onglet possède sa pile).
struct DirectoryView: View {
    let directory: DriveFile
    let driveId: Int
    let crumbs: [String]
    /// Affiche la barre de recherche (onglet Accueil uniquement).
    let showsSearchBar: Bool

    @State private var viewModel: FileGridViewModel
    @State private var searchViewModel: FileGridViewModel?
    @State private var addBusy = false
    @State private var busyMessage = ""
    @State private var addError: String?
    @State private var searchText = ""
    @State private var scrolledPastTop = false
    @State private var filters = FileFilters()
    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var pendingMove: MoveRequest?
    @State private var moveBusy = false
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false
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

    init(
        directory: DriveFile,
        driveId: Int,
        crumbs: [String],
        router: ViewerRouter,
        showsSearchBar: Bool = false,
        onOpenFolder: @escaping (DriveFile) -> Void
    ) {
        self.directory = directory
        self.driveId = driveId
        self.crumbs = crumbs
        self.router = router
        self.showsSearchBar = showsSearchBar
        self.onOpenFolder = onOpenFolder
        _viewModel = State(initialValue: FileGridViewModel(source: .directory(directory.id), driveId: driveId))
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeViewModel: FileGridViewModel {
        if isSearching, let searchViewModel {
            return searchViewModel
        }
        return viewModel
    }

    var body: some View {
        FileGridView(
            viewModel: activeViewModel,
            onOpenDirectory: onOpenFolder,
            onOpenFile: { file, siblings in
                router.open(file, siblings: siblings)
            },
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

                    if showsSearchBar && searchBarVisible {
                        VStack(spacing: 7) {
                            searchBar
                            itemCountLabel
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
                .animation(.snappy(duration: 0.25), value: searchBarVisible)
            }
        }
        .toolbar {
            if selectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { endSelection() }
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
                        prepareSelectedMove()
                    } label: {
                        Text("Déplacer")
                            .fontWeight(.semibold)
                    }
                    .disabled(selectedIDs.isEmpty || moveBusy)
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
                    .disabled(activeViewModel.items.isEmpty || moveBusy || addBusy)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if addBusy || moveBusy {
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
                onSelect: { destination in
                    pendingMove = nil
                    Task { await move(request.files, to: destination) }
                }
            )
        }
        .onChange(of: searchText) { _, _ in
            if selectionMode { endSelection() }
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                searchViewModel = nil
                return
            }
            // Debounce de 300 ms pour éviter les requêtes superflues pendant la saisie
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            let searchVM = FileGridViewModel(
                source: .search(query: trimmed, directoryId: directory.id),
                driveId: driveId
            )
            searchViewModel = searchVM
            await searchVM.reload()
        }
    }

    /// La barre apparaît lors d'un défilé vers le haut ou lorsque la recherche est active.
    private var searchBarVisible: Bool {
        alwaysShowSearch || searchFocused || !searchText.isEmpty || scrolledPastTop
    }

    /// Pastille de recherche centrée et compacte.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Rechercher dans ce dossier…", text: $searchText)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
        .frame(maxWidth: 260)
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
        router.open(random, siblings: playableFiles)
    }

    private var allSelected: Bool {
        let loadedIDs = Set(activeViewModel.items.map(\.id))
        return !loadedIDs.isEmpty && selectedIDs.isSuperset(of: loadedIDs)
    }

    private func toggleSelection(_ file: DriveFile) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    private func toggleAll() {
        let loadedIDs = Set(activeViewModel.items.map(\.id))
        if allSelected {
            selectedIDs.subtract(loadedIDs)
        } else {
            selectedIDs.formUnion(loadedIDs)
        }
    }

    private var selectionTitle: String {
        guard !selectedIDs.isEmpty else { return "Sélection" }
        return "\(selectedIDs.count) sélectionné\(selectedIDs.count > 1 ? "s" : "")"
    }

    private func startSelection() {
        searchFocused = false
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
        let files = activeViewModel.items.filter { selectedIDs.contains($0.id) }
        prepareMove(files: files)
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

        // La recherche possède sa propre vue-modèle ; rafraîchir également le
        // dossier courant évite d'y conserver une carte devenue obsolète.
        if isSearching {
            await viewModel.reload()
        }

        selectedIDs.subtract(movedIDs)
        moveBusy = false

        if movedIDs.count < ids.count {
            addError = movingViewModel.errorMessage ?? "Certains éléments n’ont pas pu être déplacés."
        }
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
            onDone: { Task { await activeViewModel.reload() } }
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
    /// placé entre la recherche et le début de la grille.
    private var itemCountLabel: some View {
        let count = activeViewModel.items.count
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
