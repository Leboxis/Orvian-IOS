import SwiftUI

struct TagIntersectionView: View {
    let driveId: Int
    let router: ViewerRouter
    let selection: TagIntersection
    let categories: [Category]
    let hasLoadedCategories: Bool
    let onOpenFolder: (DriveFile) -> Void

    var body: some View {
        Group {
            if selection.ids.isEmpty {
                ContentUnavailableView("Choisissez des tags", systemImage: "tag",
                                       description: Text("Les éléments portant tous les tags cochés apparaîtront ici."))
            } else if hasLoadedCategories && !Set(selection.ids).isSubset(of: Set(categories.map(\.id))) {
                ContentUnavailableView("Un tag n’est plus disponible", systemImage: "tag.slash",
                                       description: Text("Modifiez ou effacez le croisement pour poursuivre. Le filtre n’a pas été élargi."))
            } else {
                DebouncedTagResults(driveId: driveId, router: router, selection: selection,
                                    onOpenFolder: onOpenFolder)
                    .id(selection)
            }
        }
        .environment(\.fileBrowserScope, .tag)
    }
}

/// Each query owns its delay and browser. Replacing it immediately removes stale
/// actions; rapid checkmarks don't create a new network request for every tap.
private struct DebouncedTagResults: View {
    let driveId: Int
    let router: ViewerRouter
    let selection: TagIntersection
    let onOpenFolder: (DriveFile) -> Void
    @State private var ready = false
    @State private var path: [DriveFile] = []

    var body: some View {
        Group {
            if ready {
                FavoritesView(driveId: driveId, router: router, path: $path,
                              source: .intersection(selection), title: "Croisement de tags",
                              ownsNavigation: false, onOpenFolder: onOpenFolder)
            } else {
                ProgressView("Recherche des éléments communs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            guard !Task.isCancelled else { return }
            ready = true
        }
    }
}
