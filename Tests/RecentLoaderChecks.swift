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

        let leavingAccount = Task { await loader.refresh(driveId: 1, forceNetwork: true) }
        while FakeServer.shared.requests.count < 3 { await Task.yield() }
        loader.clear()
        TokenStore.value = "account-b"
        DirectoryListStore.shared.saved = nil
        FakeServer.shared.complete(2, fileID: 3)
        let late = await leavingAccount.value
        precondition(late == nil && DirectoryListStore.shared.saved == nil,
                     "Logout must invalidate late results and their disk writes")
        print("Forced refresh upgrade, response ordering and logout checks passed")
    }
}
