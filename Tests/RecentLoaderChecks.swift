import Foundation

@main struct RecentLoaderChecks {
    @MainActor static func main() async {
        let loader = RecentUploadsLoader.shared
        let ordinary = Task { await loader.refresh(driveId: 1) }
        while FakeServer.shared.requests.count < 1 { await Task.yield() }
        let manual = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 2 { await Task.yield() }
        precondition(FakeServer.shared.requests == [false, true], "Manual refresh must force the server")
        FakeServer.shared.complete(1, fileID: 2)
        let fresh = await manual.value
        precondition(fresh?.items.first?.id == 2)
        // Le serveur ancien finit après le nouveau, même après annulation.
        FakeServer.shared.complete(0, fileID: 1)
        let obsolete = await ordinary.value
        precondition(obsolete == nil, "An upgraded request must not return stale cached data")
        precondition(DirectoryListStore.shared.saved?.items.first?.id == 2)

        // A recently modified cache entry is not evidence of a local upload.
        DirectoryListStore.shared.saved?.items.append(DriveFile(id: 99))
        let removedElsewhere = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 3 { await Task.yield() }
        FakeServer.shared.complete(2, fileID: 2)
        let withoutGhost = await removedElsewhere.value
        precondition(withoutGhost?.items.map(\.id) == [2])

        loader.recordLocalUploads(driveId: 1, files: [DriveFile(id: 100)])
        let pendingUpload = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 4 { await Task.yield() }
        FakeServer.shared.complete(3, fileID: 2)
        let preserved = await pendingUpload.value
        precondition(Set(preserved?.items.map(\.id) ?? []) == [2, 100])

        // Once observed in the index, deletion must not resurrect the upload.
        let indexed = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 5 { await Task.yield() }
        FakeServer.shared.complete(4, fileID: 100)
        _ = await indexed.value
        let deleted = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 6 { await Task.yield() }
        FakeServer.shared.complete(5, fileID: 2)
        let afterDeletion = await deleted.value
        precondition(afterDeletion?.items.map(\.id) == [2])

        loader.recordLocalUploads(driveId: 1, files: [DriveFile(id: 101)])
        loader.removeLocalUploads(driveId: 1, fileIds: [101])
        let trashed = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 7 { await Task.yield() }
        FakeServer.shared.complete(6, fileID: 2)
        let afterTrash = await trashed.value
        precondition(afterTrash?.items.map(\.id) == [2])

        let leavingAccount = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 8 { await Task.yield() }
        loader.clear()
        TokenStore.value = "account-b"
        DirectoryListStore.shared.saved = nil
        FakeServer.shared.complete(7, fileID: 3)
        let late = await leavingAccount.value
        precondition(late == nil && DirectoryListStore.shared.saved == nil,
                     "Logout must invalidate late results and their disk writes")
        print("Forced refresh upgrade, response ordering and logout checks passed")
    }
}

