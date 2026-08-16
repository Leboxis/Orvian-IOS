import SwiftUI

/// Onglet « Favoris » : grille des favoris, avec navigation dans les
/// dossiers favoris (les dossiers sont poussés dans la pile comme dans Accueil).
struct FavoritesView: View {
    @State private var viewModel: FileGridViewModel
    @State private var filters = FileFilters()
    private let router: ViewerRouter

    @State private var path: [DriveFile] = []

    init(driveId: Int, router: ViewerRouter) {
        self.router = router
        _viewModel = State(initialValue: FileGridViewModel(source: .favorites, driveId: driveId))
    }

    var body: some View {
        NavigationStack(path: $path) {
            FileGridView(
                viewModel: viewModel,
                onOpenDirectory: { folder in
                    path.append(folder)
                },
                onOpenFile: { file, siblings in
                    router.open(file, siblings: siblings)
                },
                filters: filters
            )
            .navigationTitle("Favoris")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    FilterMenu(filters: $filters)
                }
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
}
