import Foundation

/// The runner compiles the production snapshot method and VisibleItemsCache;
/// only network/media and filtering dependencies are controllable fixtures.
@MainActor enum SnapshotFixture {
    static func check() {
        let vm = FileGridViewModel()
        let folder = DriveFile(id: 10, isDirectory: true)
        let first = DriveFile(id: 1)
        let second = DriveFile(id: 2)
        var filters = FileFilters()
        let initial = vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false)
        precondition(initial.items.isEmpty)

        // Reproduce the old Favorites failure: a child report still describes
        // revision 0 when cached data or a later page publishes revision 1.
        let childReportRevision = initial.key.itemsRevision
        vm.items = [first, folder]
        let legacyEnabled = childReportRevision == vm.itemsRevision && !initial.items.isEmpty
        precondition(!legacyEnabled)
        let cached = vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false)
        precondition(cached.items == [first, folder], "Loaded favorites must enable commands immediately")
        let requests = MediaMetadataStore.shared.snapshotRequests
        for _ in 0..<50 {
            precondition(vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false).items == cached.items)
        }
        precondition(MediaMetadataStore.shared.snapshotRequests == requests, "Unchanged renders must reuse the cached filter pass")

        vm.items.append(second)
        precondition(vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false).items == [first, folder, second])
        filters.excludedIDs = [1, 2]
        let foldersOnly = vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false).items
        precondition(foldersOnly == [folder] && !foldersOnly.isEmpty)
        precondition(foldersOnly.filter { !$0.isDirectory }.isEmpty, "Select stays available while Random is disabled")
        filters.excludedIDs.insert(10)
        precondition(vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false).items.isEmpty)
        filters.excludedIDs = []
        precondition(vm.visibleSnapshot(filters: filters, searchText: "missing", foldersFirst: false).items.isEmpty)
        filters.sort = .duration
        let sorted = vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false).items
        precondition(sorted == [second, folder, first])
        MediaMetadataStore.shared.revision += 1
        let refreshed = vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false)
        precondition(refreshed.key.metadataRevision == MediaMetadataStore.shared.revision)
        let grid = vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false)
        let list = vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false)
        precondition(grid.items == list.items && grid.key == list.key, "Presentation must not change the action population")

        let otherAccount = FileGridViewModel()
        otherAccount.items = [DriveFile(id: 99)]
        precondition(otherAccount.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false).items.map(\.id) == [99])
        precondition(vm.visibleSnapshot(filters: filters, searchText: "", foldersFirst: false).items == sorted)
    }
}
