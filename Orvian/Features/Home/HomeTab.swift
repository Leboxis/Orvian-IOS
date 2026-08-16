import SwiftUI

/// Onglet « Accueil » : navigation dans l'arborescence du drive.
struct HomeTab: View {
    let driveId: Int
    let router: ViewerRouter

    @State private var path: [DriveFile] = []
    /// Premier dossier de la racine, ouvert automatiquement au lancement.
    /// Une fois défini, il remplace la racine « Accueil » : aucun moyen de
    /// revenir dessus (pas de flèche retour ni de geste de balayage).
    @State private var startDirectory: DriveFile?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let startDirectory {
                    rootDirectory(startDirectory)
                } else {
                    rootDirectory(DriveFile.root(name: "Accueil"))
                }
            }
            .navigationDestination(for: DriveFile.self) { directory in
                let index = path.firstIndex(where: { $0.id == directory.id })
                let crumbs = index.map { Array(path[...$0].map(\.name)) } ?? []
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

    private func rootDirectory(_ directory: DriveFile) -> some View {
        DirectoryView(
            directory: directory,
            driveId: driveId,
            crumbs: [],
            router: router,
            showsSearchBar: true,
            onOpenFolder: { folder in
                path.append(folder)
            },
            onInitialLoad: { items in
                guard startDirectory == nil else { return }
                guard let firstFolder = items.first(where: \.isDirectory) else { return }
                startDirectory = firstFolder
            }
        )
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
    @State private var addBusy = false
    @State private var busyMessage = ""
    @State private var addError: String?
    @State private var searchText = ""
    @State private var scrolledPastTop = false
    @State private var filters = FileFilters()
    @FocusState private var searchFocused: Bool

    private let router: ViewerRouter
    private let onOpenFolder: (DriveFile) -> Void
    private let onInitialLoad: (([DriveFile]) -> Void)?

    init(
        directory: DriveFile,
        driveId: Int,
        crumbs: [String],
        router: ViewerRouter,
        showsSearchBar: Bool = false,
        onOpenFolder: @escaping (DriveFile) -> Void,
        onInitialLoad: (([DriveFile]) -> Void)? = nil
    ) {
        self.directory = directory
        self.driveId = driveId
        self.crumbs = crumbs
        self.router = router
        self.showsSearchBar = showsSearchBar
        self.onOpenFolder = onOpenFolder
        self.onInitialLoad = onInitialLoad
        _viewModel = State(initialValue: FileGridViewModel(source: .directory(directory.id), driveId: driveId))
    }

    var body: some View {
        FileGridView(
            viewModel: viewModel,
            onOpenDirectory: onOpenFolder,
            onOpenFile: { file, siblings in
                router.open(file, siblings: siblings)
            },
            onInitialLoad: { items in
                onInitialLoad?(items)
            },
            searchText: searchText,
            filters: filters,
            onScrolledPastTop: showsSearchBar ? { scrolledPastTop = $0 } : nil,
            contentTopInset: searchBarVisible ? DS.searchBarInset : 0,
            allowsPullToRefresh: !showsSearchBar
        )
        .animation(.snappy(duration: 0.25), value: searchBarVisible)
        .navigationTitle(crumbs.isEmpty ? directory.name : crumbs.last ?? directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if showsSearchBar {
                searchBar
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !crumbs.isEmpty {
                VStack(spacing: 0) {
                    breadcrumb
                        .frame(maxWidth: .infinity)
                    Divider().opacity(0.4)
                }
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                FilterMenu(filters: $filters)

                AddMenuButton(
                    directoryId: directory.id,
                    driveId: driveId,
                    isBusy: $addBusy,
                    busyMessage: $busyMessage,
                    errorMessage: $addError,
                    onDone: { Task { await viewModel.reload() } }
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
    }

    /// La barre apparaît uniquement en défilant dans le contenu du dossier.
    private var searchBarVisible: Bool {
        searchFocused || !searchText.isEmpty || scrolledPastTop
    }

    /// Pastille flottante, détachée du haut, centrée et translucide.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Rechercher", text: $searchText)
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
        .padding(.vertical, 8)
        .background(.bar, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
        .frame(width: 200)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .offset(y: searchBarVisible ? 0 : -64)
        .opacity(searchBarVisible ? 1 : 0)
        .allowsHitTesting(searchBarVisible)
        .animation(.snappy(duration: 0.25), value: searchBarVisible)
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

    /// Fil d'Ariane compact sous la barre de navigation.
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.caption2)
            Text(crumbs.joined(separator: "  ›  "))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.vertical, 4)
        .accessibilityLabel("Chemin : " + crumbs.joined(separator: ", "))
    }
}
