import SwiftUI

/// Onglet « Accueil » : navigation dans l'arborescence du drive.
struct HomeTab: View {
    let driveId: Int
    let router: ViewerRouter

    @State private var path: [DriveFile] = []
    /// Ouvre automatiquement le premier dossier de la racine au lancement.
    @State private var didAutoOpen = false

    var body: some View {
        NavigationStack(path: $path) {
            DirectoryView(
                directory: DriveFile.root(name: "Accueil"),
                driveId: driveId,
                crumbs: [],
                router: router,
                onOpenFolder: { folder in
                    path.append(folder)
                },
                onInitialLoad: { items in
                    guard !didAutoOpen else { return }
                    guard let firstFolder = items.first(where: \.isDirectory) else { return }
                    didAutoOpen = true
                    path.append(firstFolder)
                }
            )
            .navigationDestination(for: DriveFile.self) { directory in
                let index = path.firstIndex(where: { $0.id == directory.id })
                let crumbs = index.map { Array(path[...$0].map(\.name)) } ?? []
                DirectoryView(
                    directory: directory,
                    driveId: driveId,
                    crumbs: crumbs,
                    router: router,
                    onOpenFolder: { folder in
                        path.append(folder)
                    }
                )
            }
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

    @State private var viewModel: FileGridViewModel
    @State private var addBusy = false
    @State private var busyMessage = ""
    @State private var addError: String?

    private let router: ViewerRouter
    private let onOpenFolder: (DriveFile) -> Void
    private let onInitialLoad: (([DriveFile]) -> Void)?

    init(
        directory: DriveFile,
        driveId: Int,
        crumbs: [String],
        router: ViewerRouter,
        onOpenFolder: @escaping (DriveFile) -> Void,
        onInitialLoad: (([DriveFile]) -> Void)? = nil
    ) {
        self.directory = directory
        self.driveId = driveId
        self.crumbs = crumbs
        self.router = router
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
            }
        )
        .navigationTitle(crumbs.isEmpty ? directory.name : crumbs.last ?? directory.name)
        .navigationBarTitleDisplayMode(.inline)
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
            ToolbarItem(placement: .topBarTrailing) {
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
