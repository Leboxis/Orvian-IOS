import Foundation

@main
struct MutationSafetyChecks {
    @MainActor
    static func main() throws {
        var file = DriveFile.root(name: "Fichier déplacé")
        file.parentId = 10
        file.path = "/ancien/fichier"
        file.isFavorite = true
        file.categories = [FileCategory(categoryId: 42)]
        let move = FileGridMutation.moved(driveId: 7, fileIds: [file.id], destinationDirectoryId: 20)

        let retainedSources: [FileSource] = [.favorites, .category(42), .recents(), .search(query: "Fichier", directoryId: nil)]
        for source in retainedSources {
            var items = [file]
            precondition(!move.applyMove(to: &items, source: source))
            precondition(items.count == 1 && items[0].isFavorite == true)
            precondition(items[0].categories == file.categories)
            precondition(items[0].parentId == 20 && items[0].path == nil)
            let confirmed = items
            precondition(!move.applyMove(to: &items, source: source))
            precondition(items == confirmed, "Repeated delivery must be harmless")
        }
        var origin = [file]
        precondition(!move.applyMove(to: &origin, source: .directory(10)))
        precondition(origin.isEmpty)
        var destination: [DriveFile] = []
        precondition(move.applyMove(to: &destination, source: .directory(20)),
                     "An already cached destination must fetch the incoming file")
        var scopedSearch = [file]
        precondition(move.applyMove(to: &scopedSearch, source: .search(query: "Fichier", directoryId: 10)))
        var trash = [file]
        precondition(!move.applyMove(to: &trash, source: .trash))
        precondition(trash == [file])

        // Partial success: IDs not confirmed by the server must stay untouched.
        let unrelated = FileGridMutation.moved(driveId: 7, fileIds: [999], destinationDirectoryId: 20)
        var unchanged = [file]
        precondition(!unrelated.applyMove(to: &unchanged, source: .favorites))
        precondition(unchanged == [file])

        let center = FileGridMutationCenter.shared
        let snapshot = DirectoryListSnapshot(items: [file], cursor: nil, hasMore: false,
                                             totalItemCount: 1, orderBy: [], order: "asc",
                                             fetchedAt: Date(timeIntervalSinceNow: -10))
        center.publish(move)
        precondition(center.isSnapshotStale(snapshot, source: .favorites, driveId: 7))
        var corrected = snapshot
        move.applyMove(to: &corrected.items, source: .favorites)
        precondition(!center.isSnapshotStale(corrected, source: .favorites, driveId: 7))
        precondition(!center.isSnapshotStale(snapshot, source: .favorites, driveId: 8))
        var empty = snapshot
        empty.items = []
        precondition(center.isSnapshotStale(empty, source: .directory(20), driveId: 7))
        precondition(!center.isSnapshotStale(empty, source: .directory(10), driveId: 7))
        print("Move and cache consistency checks passed")
    }
}
