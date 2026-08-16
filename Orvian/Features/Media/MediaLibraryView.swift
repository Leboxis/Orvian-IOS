import SwiftUI

/// Onglet « Média » : toutes les photos et vidéos du drive, groupées par mois.
struct MediaLibraryView: View {
    @State private var viewModel: FileGridViewModel
    private let router: ViewerRouter

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    init(driveId: Int, router: ViewerRouter) {
        self.router = router
        _viewModel = State(initialValue: FileGridViewModel(source: .media, driveId: driveId))
    }

    var body: some View {
        NavigationStack {
            FileGridView(
                viewModel: viewModel,
                grouping: (component: .month, title: { Self.monthFormatter.string(from: $0) }),
                onOpenFile: { file, siblings in
                    router.open(file, siblings: siblings)
                }
            )
            .navigationTitle("Média")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
