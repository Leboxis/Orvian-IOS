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
        // Home/recent grid, tab prefetch and Profile join the same cold request.
        let cold = Task { await loader.refresh(driveId: 1) }
        while FakeServer.shared.requests.count < 9 { await Task.yield() }
        let profile = Task { await loader.refresh(driveId: 1) }
        for _ in 0..<20 { await Task.yield() }
        precondition(FakeServer.shared.requests.count == 9, "Cold consumers must share one first page")
        FakeServer.shared.complete(8, fileID: 10)
        let firstPage = await cold.value
        let profilePage = await profile.value
        precondition(firstPage?.items.map(\.id) == profilePage?.items.map(\.id))
        _ = await loader.refresh(driveId: 1)
        precondition(FakeServer.shared.requests.count == 9, "Fresh results must be reused")

        // Even with a fresh cache, an ordinary consumer joins a forced refresh.
        let forced = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 10 { await Task.yield() }
        let joiningFreshCache = Task { await loader.refresh(driveId: 1) }
        for _ in 0..<20 { await Task.yield() }
        FakeServer.shared.complete(9, fileID: 11)
        _ = await forced.value
        let joined = await joiningFreshCache.value
        precondition(joined?.items.first?.id == 11, "In-flight revalidation must win over cached content")

        // A credential change must not join another account's in-flight task,
        // even if its drive ID is the same and clear() has not yet run.
        let previousCredential = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 11 { await Task.yield() }
        TokenStore.value = "account-c"
        DirectoryListStore.shared.saved = nil
        let currentCredential = Task { await loader.refresh(driveId: 1) }
        while FakeServer.shared.requests.count < 12 { await Task.yield() }
        FakeServer.shared.complete(10, fileID: 12)
        let previousResult = await previousCredential.value
        precondition(previousResult == nil)
        FakeServer.shared.complete(11, fileID: 13)
        let currentResult = await currentCredential.value
        precondition(currentResult?.items.first?.id == 13)

        // Cancelling one waiter must not cancel the request used by another view.
        let owner = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 13 { await Task.yield() }
        let cancelledWaiter = Task { await loader.refresh(driveId: 1) }
        for _ in 0..<20 { await Task.yield() }
        cancelledWaiter.cancel()
        FakeServer.shared.complete(12, fileID: 14)
        let ownerResult = await owner.value
        let cancelledResult = await cancelledWaiter.value
        precondition(ownerResult?.items.first?.id == 14 && cancelledResult == nil)
        print("Recent sharing, cache reuse, refresh ordering, credentials and logout checks passed")
    }
}

