import SwiftUI

/// Vue paginée (12 éléments par page, pagination infinie au défilement)
/// pour les uploads récents et les favoris dans l'onglet Profil.
struct RecentFilesView: View {
    let driveId: Int
    let title: String
    let source: FileSource
    let router: ViewerRouter

    @State private var viewModel: FileGridViewModel
    @State private var filters = FileFilters()
    @State private var path: [DriveFile] = []

    init(driveId: Int, title: String, source: FileSource, router: ViewerRouter) {
        self.driveId = driveId
        self.title = title
        self.source = source
        self.router = router
        _viewModel = State(initialValue: FileGridViewModel(source: source, driveId: driveId))
    }

    var body: some View {
        FileGridView(
            viewModel: viewModel,
            onOpenDirectory: { folder in
                path.append(folder)
            },
            onOpenFile: { file, siblings in
                router.open(
                    file,
                    siblings: siblings,
                    filters: filters,
                    searchText: "",
                    viewModel: viewModel
                )
            },
            filters: filters
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                FilterMenu(filters: $filters)
            }
        }
        .navigationDestination(for: DriveFile.self) { directory in
            DirectoryView(
                directory: directory,
                driveId: driveId,
                crumbs: [title, directory.name],
                router: router,
                onOpenFolder: { folder in
                    path.append(folder)
                }
            )
        }
    }
}
