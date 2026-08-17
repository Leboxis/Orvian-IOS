import SwiftUI

/// Onglet « Accueil » : navigation dans l'arborescence du drive.
struct HomeTab: View {
    let driveId: Int
    let router: ViewerRouter
    @Binding var path: [DriveFile]

    /// Premier sous-dossier du dossier qui servait auparavant de racine.
    /// Il devient la nouvelle racine de navigation : son parent n'est jamais
    /// ajouté au NavigationStack et n'est donc pas accessible par retour.
    @State private var startDirectory: DriveFile?
    private let service = KDriveService()

    private var cacheKey: String { "home_start_dir_n_plus_1_\(driveId)" }
    private var previousCacheKey: String { "home_start_dir_\(driveId)" }

    init(driveId: Int, router: ViewerRouter, path: Binding<[DriveFile]>) {
        self.driveId = driveId
        self.router = router
        self._path = path

        if let data = UserDefaults.standard.data(forKey: "home_start_dir_n_plus_1_\(driveId)"),
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

    /// Résout une seule fois le niveau n+1. L'ancien cache fournit le niveau
    /// qui servait jusque-là de racine, ce qui évite une requête supplémentaire
    /// lors de la migration. Sans ancien cache, la racine du drive est d'abord
    /// parcourue pour retrouver ce même niveau.
    private func resolveStartDirectory() async {
        let defaults = UserDefaults.standard
        var currentRoot: DriveFile?

        if let data = defaults.data(forKey: previousCacheKey),
           let cached = try? JSONDecoder().decode(DriveFile.self, from: data) {
            currentRoot = cached
        }

        if currentRoot == nil,
           let page = try? await service.page(.directory(1), driveId: driveId, cursor: nil) {
            currentRoot = page.data?.first(where: \.isDirectory)
        }

        guard !Task.isCancelled else { return }
        guard let currentRoot else {
            startDirectory = DriveFile.root(name: "Accueil")
            return
        }

        let page = try? await service.page(.directory(currentRoot.id), driveId: driveId, cursor: nil)
        guard !Task.isCancelled else { return }

        // Si aucun sous-dossier n'existe ou si le réseau échoue, conserver le
        // dossier actuel évite de rendre l'Accueil inutilisable.
        let resolved = page?.data?.first(where: \.isDirectory) ?? currentRoot
        path.removeAll()
        startDirectory = resolved

        if let data = try? JSONEncoder().encode(resolved) {
            defaults.set(data, forKey: cacheKey)
        }
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
    @FocusState private var searchFocused: Bool

    private let router: ViewerRouter
    private let onOpenFolder: (DriveFile) -> Void

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
            allowsPullToRefresh: !showsSearchBar
        )
        .navigationTitle(crumbs.last ?? directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                breadcrumb
                    .frame(maxWidth: .infinity)

                if showsSearchBar && searchBarVisible {
                    searchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
            .animation(.snappy(duration: 0.25), value: searchBarVisible)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                FilterMenu(filters: $filters)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                randomFileButton

                AddMenuButton(
                    directoryId: directory.id,
                    driveId: driveId,
                    isBusy: $addBusy,
                    busyMessage: $busyMessage,
                    errorMessage: $addError,
                    onDone: { Task { await activeViewModel.reload() } }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if addBusy {
                busyIndicator
            }
        }
        .alert("Impossible", isPresented: addErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
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
        searchFocused || !searchText.isEmpty || scrolledPastTop
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

    /// Bulle compacte indiquant le chemin et le nombre d'éléments, rapprochée du titre.
    private var breadcrumb: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .medium))
            Text(crumbs.joined(separator: "  ›  "))
                .lineLimit(1)
                .truncationMode(.head)

            Text("•")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)

            let count = activeViewModel.items.count
            Text("\(count) élément\(count > 1 ? "s" : "")")
                .lineLimit(1)
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
        .accessibilityLabel("Chemin : " + crumbs.joined(separator: ", ") + ", \(activeViewModel.items.count) éléments")
    }
}
