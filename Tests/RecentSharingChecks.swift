import Foundation

@main struct RecentSharingChecks {
    @MainActor static func main() async {
        let loader = RecentUploadsLoader.shared
        let store = DirectoryListStore.shared
        let server = FakeServer.shared
        precondition(store.key(1, order: "asc") != store.key(1, order: "desc"))
        precondition(store.key(1, orderBy: []) != store.key(1, orderBy: ["updated_at"]))
        func snapshot(_ ids: [Int]) -> DirectoryListSnapshot {
            DirectoryListSnapshot(items: ids.map { DriveFile(id: $0) }, cursor: "next", hasMore: true,
                totalItemCount: nil, orderBy: [], order: "asc", fetchedAt: .distantPast)
        }
        store.suspendDisk = true
        let restoring = Task { await loader.cachedSnapshot(driveId: 1) }
        while store.pendingDisk == nil { await Task.yield() }
        let network = Task { await loader.refresh(driveId: 1) }
        while server.drives.count < 1 { await Task.yield() }
        server.complete(0, fileID: 10)
        _ = await network.value
        store.finishDisk(snapshot([1]))
        let restored = await restoring.value
        precondition(restored?.items.first?.id == 10, "A late disk read must not overwrite the network")
        precondition(store.entries[store.key(1)]?.items.first?.id == 10)

        store.entries.removeAll()
        loader.clear()
        let missingDisk = Task { await loader.cachedSnapshot(driveId: 1) }
        while store.pendingDisk == nil { await Task.yield() }
        store.entries[store.key(1)] = snapshot([99]) // Upload merged during a disk miss.
        store.finishDisk(nil)
        let afterDiskMiss = await missingDisk.value
        precondition(afterDiskMiss?.items.first?.id == 99, "A disk miss must still return newer memory")

        store.entries.removeAll()
        let oldDisk = Task { await loader.cachedSnapshot(driveId: 1) }
        while store.pendingDisk == nil { await Task.yield() }
        loader.clear() // Same credential: generation is still needed.
        store.finishDisk(snapshot([2]))
        let clearedDisk = await oldDisk.value
        precondition(clearedDisk == nil && store.entries.isEmpty)

        let accountDisk = Task { await loader.cachedSnapshot(driveId: 1) }
        while store.pendingDisk == nil { await Task.yield() }
        TokenStore.value = "account-b"
        store.finishDisk(snapshot([3]))
        let wrongAccount = await accountDisk.value
        precondition(wrongAccount == nil && store.entries.isEmpty)
        store.suspendDisk = false

        // Separate drives cannot share an in-flight page or cache entry.
        let driveOne = Task { await loader.refresh(driveId: 1) }
        let driveTwo = Task { await loader.refresh(driveId: 2) }
        while server.drives.count < 3 { await Task.yield() }
        for index in 1..<3 { server.complete(index, fileID: server.drives[index] * 10) }
        let one = await driveOne.value
        let two = await driveTwo.value
        precondition(one?.items.first?.id == 10 && two?.items.first?.id == 20)

        // A removal confirmed during GET must win over a late server response.
        let removing = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while server.drives.count < 4 { await Task.yield() }
        FileGridMutationCenter.shared.removedIDs = [10]
        FileGridMutationCenter.shared.recordedAt = Date()
        store.entries[store.key(1)] = snapshot([11])
        server.complete(3, fileID: 10)
        let afterRemoval = await removing.value
        precondition(afterRemoval?.items.first?.id == 11, "The current confirmed cache must survive a stale GET")
        precondition(store.entries[store.key(1)]?.items.first?.id == 11)

        // Confirmed uploads arriving during GET remain available before indexing.
        let uploading = Task { await loader.refresh(driveId: 2, forceNetwork: true) }
        while server.drives.count < 5 { await Task.yield() }
        loader.recordLocalUploads(driveId: 2, files: [DriveFile(id: 21), DriveFile(id: 99, isDirectory: true)])
        server.complete(4, fileID: 20)
        let merged = await uploading.value
        precondition(merged?.items.map(\.id) == [21, 20])
        // An already paginated grid retains its own items and cursor, while
        // Profile and a following grid reload reuse the newly validated head.
        store.entries[store.key(3)] = snapshot(Array(100..<120))
        let paginatedRefresh = Task { await loader.refresh(driveId: 3) }
        while server.drives.count < 6 { await Task.yield() }
        server.complete(5, fileID: 30)
        let freshHead = await paginatedRefresh.value
        precondition(freshHead?.items.map(\.id) == [30])
        precondition(store.entries[store.key(3)]?.items.map(\.id) == Array(100..<120))
        precondition(store.entries[store.key(3)]?.cursor == "next")
        let cachedHead = await loader.cachedSnapshot(driveId: 3)
        let gridHead = await loader.refresh(driveId: 3)
        precondition(cachedHead?.items.map(\.id) == [30] && gridHead?.items.map(\.id) == [30])
        precondition(server.drives.count == 6, "Profile followed by grid must reuse the validated first page")

        loader.recordLocalUploads(driveId: 3, files: [DriveFile(id: 31)])
        let locallyMergedHead = await loader.cachedSnapshot(driveId: 3)
        precondition(locallyMergedHead?.items.map(\.id) == [31, 30])
        loader.removeLocalUploads(driveId: 3, fileIds: [31])
        let removedFromHead = await loader.cachedSnapshot(driveId: 3)
        precondition(removedFromHead?.items.map(\.id) == [30])

        // A private head cannot leak to another credential or survive clear.
        TokenStore.value = "account-c"
        let otherCredentialHead = await loader.cachedSnapshot(driveId: 3)
        precondition(otherCredentialHead == nil)
        let otherCredentialRefresh = Task { await loader.refresh(driveId: 3) }
        while server.drives.count < 7 { await Task.yield() }
        server.complete(6, fileID: 40)
        _ = await otherCredentialRefresh.value
        store.entries.removeAll()
        loader.clear()
        let clearedHead = await loader.cachedSnapshot(driveId: 3)
        precondition(clearedHead == nil)
        print("Recent cache races, isolation, upload merge and paginated-head reuse checks passed")
    }
}
