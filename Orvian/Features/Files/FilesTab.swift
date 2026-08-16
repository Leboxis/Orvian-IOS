import SwiftUI

/// Onglet « Fichiers » : navigation dans l'arborescence.
struct FilesTab: View {
    let driveId: Int
    let driveName: String
    let router: ViewerRouter

    @State private var path: [DriveFile] = []

    var body: some View {
        NavigationStack(path: $path) {
            DirectoryView(
                directory: DriveFile.root(name: driveName),
                driveId: driveId,
                crumbs: [],
                router: router,
                onOpenFolder: { folder in
                    path.append(folder)
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
    /// Racine du drive (id 1), habillée du nom du drive pour l'affichage.
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
            addedAt: nil,
            lastModifiedAt: nil
        )
    }
}

/// Contenu d'un dossier, avec breadcrumb compact.
struct DirectoryView: View {
    let directory: DriveFile
    let driveId: Int
    let crumbs: [String]

    @State private var viewModel: FileGridViewModel
    private let router: ViewerRouter
    private let onOpenFolder: (DriveFile) -> Void

    init(
        directory: DriveFile,
        driveId: Int,
        crumbs: [String],
        router: ViewerRouter,
        onOpenFolder: @escaping (DriveFile) -> Void
    ) {
        self.directory = directory
        self.driveId = driveId
        self.crumbs = crumbs
        self.router = router
        self.onOpenFolder = onOpenFolder
        _viewModel = State(initialValue: FileGridViewModel(source: .directory(directory.id), driveId: driveId))
    }

    var body: some View {
        FileGridView(
            viewModel: viewModel,
            onOpenDirectory: onOpenFolder,
            onOpenFile: { file, siblings in
                router.open(file, siblings: siblings)
            }
        )
        .navigationTitle(directory.name)
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
