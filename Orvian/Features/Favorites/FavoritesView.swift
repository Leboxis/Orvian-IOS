import SwiftUI

/// Onglet « Favoris ».
struct FavoritesView: View {
    @State private var viewModel: FileGridViewModel
    private let router: ViewerRouter

    init(driveId: Int, router: ViewerRouter) {
        self.router = router
        _viewModel = State(initialValue: FileGridViewModel(source: .favorites, driveId: driveId))
    }

    var body: some View {
        NavigationStack {
            FileGridView(
                viewModel: viewModel,
                onOpenFile: { file, siblings in
                    router.open(file, siblings: siblings)
                }
            )
            .navigationTitle("Favoris")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
