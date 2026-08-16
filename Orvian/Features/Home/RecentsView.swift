import SwiftUI

/// Onglet « Actualité » : fichiers récents groupés par jour.
struct RecentsView: View {
    @State private var viewModel: FileGridViewModel
    private let router: ViewerRouter

    init(driveId: Int, router: ViewerRouter) {
        self.router = router
        _viewModel = State(initialValue: FileGridViewModel(source: .recents, driveId: driveId))
    }

    var body: some View {
        NavigationStack {
            FileGridView(
                viewModel: viewModel,
                grouping: (component: .day, title: FileGridViewModel.dayTitle(for:)),
                onOpenFile: { file, siblings in
                    router.open(file, siblings: siblings)
                }
            )
            .navigationTitle("Actualité")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
