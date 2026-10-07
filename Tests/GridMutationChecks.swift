import Foundation

@main struct GridMutationChecks {
    @MainActor static var server: CallbackServer { .shared }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Expected callback was never registered")
    }
    @MainActor static func seeded(_ source: FileSource = .directory(1)) -> FileGridViewModel {
        let vm = FileGridViewModel(source)
        vm.items = [DriveFile(id: 1), DriveFile(id: 2)]
        vm.loadedOnce = true
        vm.totalItemCount = 20
        vm.cursor = "next"
        vm.hasMore = true
        return vm
    }
    @MainActor static func assertUnlocked(_ vm: FileGridViewModel) {
        precondition(!vm.isReloading && !vm.isInitialLoading && !vm.isLoadingMore,
                     "Discarding stale callbacks must still release loading flags")
    }
    @MainActor static func stalePage(_ mutation: FileGridMutation, source: FileSource,
                                      pagination: Bool) async {
        let vm = seeded(source)
        let task = Task {
            if pagination { await vm.loadMoreIfNeeded() }
            else { await vm.reload(refreshCount: false) }
        }
        await until { !server.pages.isEmpty }
        vm.apply(mutation)
        let confirmed = vm.items
        let confirmedCount = vm.totalItemCount
        server.finishPage([DriveFile(id: 1), DriveFile(id: 3)], cursor: "obsolete", hasMore: false)
        await task.value
        precondition(vm.items == confirmed, "An obsolete page must not erase confirmed mutations")
        precondition(vm.totalItemCount == confirmedCount && vm.cursor == "next" && vm.hasMore)
        assertUnlocked(vm)
        // Retrying after the confirmation uses a fresh generation and remains functional.
        let retry = Task {
            if pagination { await vm.loadMoreIfNeeded() }
            else { await vm.reload(refreshCount: false) }
        }
        await until { !server.pages.isEmpty }
        server.finishPage(confirmed + [DriveFile(id: 4)], cursor: "fresh", hasMore: false)
        await retry.value
        precondition(vm.items.contains { $0.id == 4 } && vm.cursor == "fresh")
        assertUnlocked(vm)
    }
    @MainActor static func main() async {
        let variants: [(FileGridMutation, FileSource)] = [
            (.favorite(driveId: 7, fileId: 1, isFavorite: true), .directory(1)),
            (.favorite(driveId: 7, fileId: 1, isFavorite: false), .favorites),
            (.rename(driveId: 7, fileId: 1, name: "confirmed"), .directory(1)),
            (.color(driveId: 7, fileId: 1, color: "confirmed"), .directory(1)),
            (.category(driveId: 7, fileId: 1, category: Category(id: 8), applied: true), .directory(1)),
            (.category(driveId: 7, fileId: 1, category: Category(id: 8), applied: false), .category(8)),
            (.trashed(driveId: 7, fileIds: [1]), .directory(1)),
            (.removal(driveId: 7, fileIds: [1]), .directory(1)),
            (.moved(driveId: 7, fileIds: [1], destinationDirectoryId: 9), .directory(1)),
            (.moved(driveId: 7, fileIds: [1], destinationDirectoryId: 9), .favorites),
            (.uploaded(driveId: 7, files: [DriveFile(id: 3)]), .recents),
            (.uploaded(driveId: 7, files: [DriveFile(id: 3)]), .directory(1)),
            (.restored(driveId: 7, fileIds: [1], destinationDirectoryIds: [1]), .trash),
        ]
        for (mutation, source) in variants {
            await stalePage(mutation, source: source, pagination: false)
            await stalePage(mutation, source: source, pagination: true)
        }

        // Count and page are independent callbacks; neither old count ordering is safe.
        for countFirst in [true, false] {
            let vm = seeded()
            let task = Task { await vm.reload() }
            await until { !server.pages.isEmpty && !server.counts.isEmpty }
            if countFirst { server.finishCount(100) }
            vm.apply(.trashed(driveId: 7, fileIds: [1]))
            precondition(vm.totalItemCount == 19)
            server.finishPage([DriveFile(id: 1)], cursor: "old")
            if !countFirst { server.finishCount(100) }
            await task.value
            precondition(vm.items.map(\.id) == [2] && vm.totalItemCount == 19)
            assertUnlocked(vm)
        }
        let afterPage = seeded()
        let waitingCount = Task { await afterPage.reload() }
        await until { !server.pages.isEmpty && !server.counts.isEmpty }
        server.finishPage([DriveFile(id: 1), DriveFile(id: 2)])
        await until { !afterPage.isReloading }
        afterPage.apply(.trashed(driveId: 7, fileIds: [1]))
        server.finishCount(100)
        await waitingCount.value
        precondition(afterPage.totalItemCount == 19 && afterPage.items.map(\.id) == [2])

        // Originating/broadcast self-echoes must not double-adjust the badge.
        let echoed = seeded()
        let removal = FileGridMutation.trashed(driveId: 7, fileIds: [1])
        echoed.apply(removal)
        echoed.apply(removal)
        precondition(echoed.totalItemCount == 19)
        let uploadEcho = FileGridMutation.uploaded(driveId: 7, files: [DriveFile(id: 3)])
        echoed.apply(uploadEcho)
        echoed.apply(uploadEcho)
        precondition(echoed.totalItemCount == 20 && echoed.items.map(\.id) == [2, 3])

        // Originating trash confirmation must work without a view echo.
        let trashed = seeded()
        let beforeTrash = Task { await trashed.reload() }
        await until { !server.pages.isEmpty && !server.counts.isEmpty }
        let trashWrite = Task { await trashed.trash(DriveFile(id: 1)) }
        await until { !server.writes.isEmpty }
        server.finishWrite()
        await trashWrite.value
        server.finishPage([DriveFile(id: 1), DriveFile(id: 2)])
        // An obsolete page must release flags even while its count is outstanding.
        await until { !trashed.isReloading && !trashed.isInitialLoading }
        server.finishCount(100)
        await beforeTrash.value
        precondition(trashed.items.map(\.id) == [2] && trashed.totalItemCount == 19)
        assertUnlocked(trashed)

        // Originating upload/category confirmations must invalidate even without a view echo.
        for upload in [true, false] {
            let vm = seeded()
            let task = Task { await vm.reload() }
            await until { !server.pages.isEmpty && !server.counts.isEmpty }
            if upload { vm.mergeUploaded([DriveFile(id: 3)]) }
            else { vm.updateCategories(for: DriveFile(id: 1), category: Category(id: 8), applied: true) }
            let confirmed = vm.items
            server.finishPage([DriveFile(id: 1)])
            server.finishCount(100)
            await task.value
            precondition(vm.items == confirmed && vm.totalItemCount == (upload ? 21 : 20))
            assertUnlocked(vm)
        }

        // A GET can finish between optimistic change and API success; success must reassert it.
        for kind in 0..<3 {
            for pageBeforeSuccess in [true, false] {
                let vm = seeded()
                let load = Task { await vm.reload(refreshCount: false) }
                await until { !server.pages.isEmpty }
                let write = Task {
                    if kind == 0 { _ = await vm.toggleFavorite(DriveFile(id: 1)) }
                    else if kind == 1 { await vm.rename(DriveFile(id: 1), name: "confirmed") }
                    else { await vm.setColor(DriveFile(id: 1), color: "confirmed") }
                }
                await until { !server.writes.isEmpty }
                if pageBeforeSuccess {
                    server.finishPage([DriveFile(id: 1), DriveFile(id: 2)])
                    await load.value
                }
                server.finishWrite()
                await write.value
                if !pageBeforeSuccess {
                    server.finishPage([DriveFile(id: 1), DriveFile(id: 2)])
                    await load.value
                }
                let file = vm.items.first { $0.id == 1 }!
                precondition(kind != 0 || file.isFavorite == true)
                precondition(kind != 1 || file.name == "confirmed")
                precondition(kind != 2 || file.color == "confirmed")
                assertUnlocked(vm)
            }
        }

        // Stale failure must not replace the confirmed state with a retry error.
        let failed = seeded()
        let failedLoad = Task { await failed.loadMoreIfNeeded() }
        await until { !server.pages.isEmpty }
        failed.apply(.trashed(driveId: 7, fileIds: [1]))
        server.failPage()
        await failedLoad.value
        precondition(failed.errorMessage == nil && failed.items.map(\.id) == [2])
        assertUnlocked(failed)

        // Initial loading cannot settle on an empty list after discarding its only page.
        let initial = FileGridViewModel()
        let first = Task { await initial.reload(refreshCount: false) }
        await until { !server.pages.isEmpty }
        initial.apply(.trashed(driveId: 7, fileIds: [1]))
        server.finishPage([DriveFile(id: 1)])
        await first.value
        await until { !server.pages.isEmpty }
        server.finishPage([DriveFile(id: 2)])
        await until { initial.items.map(\.id) == [2] && !initial.isReloading }
        assertUnlocked(initial)

        // A failed obsolete first GET must also retry, not settle on a blank screen.
        let initialFailure = FileGridViewModel()
        let firstFailure = Task { await initialFailure.reload(refreshCount: false) }
        await until { !server.pages.isEmpty }
        initialFailure.apply(.favorite(driveId: 7, fileId: 99, isFavorite: true))
        server.failPage()
        await firstFailure.value
        await until { !server.pages.isEmpty }
        server.finishPage([DriveFile(id: 4)])
        await until { initialFailure.items.map { $0.id } == [4] && !initialFailure.isReloading }
        precondition(initialFailure.errorMessage == nil)
        assertUnlocked(initialFailure)

        // Changing ordering invalidates the old cursor. A mutation during the
        // first sorted page triggers an automatic retry, even on a loaded grid.
        for sortedResponseFails in [false, true] {
            let sorted = seeded()
            let sorting = Task {
                await sorted.reload(sortedBy: FileFilters(serverOrderBy: ["updated_at"], serverOrder: "desc"),
                                    refreshCount: false)
            }
            await until { !server.pages.isEmpty }
            precondition(sorted.cursor == nil && !sorted.hasMore && sorted.orderingNeedsReload)
            sorted.apply(.favorite(driveId: 7, fileId: 1, isFavorite: true))
            if sortedResponseFails { server.failPage() }
            else { server.finishPage([DriveFile(id: 1)], cursor: "obsolete-order", hasMore: true) }
            await sorting.value
            await until { !server.pages.isEmpty }
            let retryRequest = server.requestedPages.last!
            precondition(retryRequest.cursor == nil && retryRequest.orderBy == ["updated_at"] && retryRequest.order == "desc")
            server.finishPage([DriveFile(id: 3)], cursor: "sorted-next", hasMore: true)
            await until { !sorted.isReloading && sorted.items.map { $0.id } == [3] }
            precondition(!sorted.orderingNeedsReload)
            let more = Task { await sorted.loadMoreIfNeeded() }
            await until { !server.pages.isEmpty }
            precondition(server.requestedPages.last!.cursor == "sorted-next")
            precondition(server.requestedPages.last!.order == "desc")
            server.finishPage([DriveFile(id: 4)])
            await more.value
            precondition(sorted.items.map { $0.id } == [3, 4])
            assertUnlocked(sorted)
        }

        // The canonical recent first page uses the shared loader, not a second
        // service request. Subsequent pages still use the returned cursor.
        let recent = FileGridViewModel(.recents)
        // FileFilters defaults to descending even when Original has no server fields.
        recent.order = "desc"
        let recentCount = server.recentLoads
        let directCount = server.requestedPages.count
        let recentJob = Task { await recent.reload(refreshCount: false) }
        await until { !server.pages.isEmpty }
        precondition(server.recentLoads == recentCount + 1)
        precondition(server.requestedPages.count == directCount)
        server.finishPage([DriveFile(id: 8)], cursor: "recent-next", hasMore: true)
        await recentJob.value
        precondition(recent.order == "asc", "Original recent ordering must use the canonical cache key")
        let recentMore = Task { await recent.loadMoreIfNeeded() }
        await until { !server.pages.isEmpty }
        precondition(server.recentLoads == recentCount + 1)
        precondition(server.requestedPages.last!.cursor == "recent-next")
        server.finishPage([DriveFile(id: 9)])
        await recentMore.value
        precondition(recent.items.map { $0.id } == [8, 9])
        assertUnlocked(recent)

        // Another drive does not invalidate this request.
        let otherDrive = seeded()
        let valid = Task { await otherDrive.loadMoreIfNeeded() }
        await until { !server.pages.isEmpty }
        otherDrive.apply(.trashed(driveId: 8, fileIds: [1]))
        server.finishPage([DriveFile(id: 3)])
        await valid.value
        precondition(otherDrive.items.map(\.id) == [1, 2, 3])
        assertUnlocked(otherDrive)
        precondition(server.pages.isEmpty && server.counts.isEmpty && server.writes.isEmpty)
        print("Confirmed mutations survive reload, pagination, count and optimistic callback permutations")
    }
}
