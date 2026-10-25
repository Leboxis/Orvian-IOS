import Foundation

struct DriveFile: Equatable {
    let id: Int
    var isVisible = true
}

@MainActor final class PageModel {
    var source = 1
    var items = [DriveFile(id: 1)]
    var pages: [[DriveFile]] = []
    var itemsRevision = 1
    var hasMore = true
    var isInitialLoading = false
    var isReloading = false
    var isLoadingMore = false
    var errorMessage: String?
    var requests = 0
    var failNext = false
    var makeNoProgress = false
    var cancelNext = false
    var afterLoad: (() -> Void)?

    func loadMoreIfNeeded() async {
        guard hasMore, !isReloading, !isLoadingMore, !isInitialLoading else { return }
        requests += 1
        if cancelNext {
            withUnsafeCurrentTask { $0?.cancel() }
            return
        }
        if failNext { errorMessage = "offline"; return }
        if makeNoProgress { return }
        guard !pages.isEmpty else { hasMore = false; return }
        items += pages.removeFirst()
        itemsRevision += 1
        hasMore = !pages.isEmpty
        afterLoad?()
    }
}

@MainActor final class PaginationFixture {
    let viewModel = PageModel()
    var visibleItems: [DriveFile] {
        viewModel.items.filter { $0.isVisible || resolvedVisibleIDs.contains($0.id) }
    }
    var metadataResolutions = 0
    var metadataMakesVisible: Set<Int> = []
    var resolvedVisibleIDs: Set<Int> = []
    func resolveVideoMetadata(for items: [DriveFile]) async {
        metadataResolutions += 1
        resolvedVisibleIDs.formUnion(items.map(\.id).filter { metadataMakesVisible.contains($0) })
    }
    // PRODUCTION_PAGINATION
    func check() async {
        viewModel.pages = [[DriveFile(id: 2, isVisible: false)],
                           [DriveFile(id: 3, isVisible: false)],
                           [DriveFile(id: 4)], [DriveFile(id: 5)]]
        await loadMoreAfterMetadataResolution()
        precondition(viewModel.requests == 3, "Hidden pages must not strand older visible matches")
        precondition(visibleItems.map(\.id) == [1, 4])
        precondition(viewModel.hasMore, "Stop at the next visible result, not the end of the drive")
        precondition(metadataResolutions >= 2, "Resolve new video metadata before judging visibility")

        let empty = PaginationFixture()
        empty.viewModel.items = []
        empty.viewModel.pages = [[DriveFile(id: 2, isVisible: false)], [DriveFile(id: 3)]]
        await empty.loadMoreAfterMetadataResolution()
        precondition(empty.viewModel.requests == 2 && empty.visibleItems.map(\.id) == [3])

        let exhausted = PaginationFixture()
        exhausted.viewModel.pages = [[DriveFile(id: 2, isVisible: false)]]
        await exhausted.loadMoreAfterMetadataResolution()
        precondition(exhausted.viewModel.requests == 1 && !exhausted.viewModel.hasMore)

        let video = PaginationFixture()
        video.metadataMakesVisible = [2]
        video.viewModel.pages = [[DriveFile(id: 2, isVisible: false)], [DriveFile(id: 3)]]
        await video.loadMoreAfterMetadataResolution()
        precondition(video.viewModel.requests == 1 && video.visibleItems.map(\.id) == [1, 2],
                     "Metadata must be resolved before deciding that the new page is wholly hidden")

        let changed = PaginationFixture()
        changed.viewModel.pages = [[DriveFile(id: 2, isVisible: false)], [DriveFile(id: 3)]]
        // The view cancels its task on filter/search/source changes. Do not model the
        // View's value-captured filters as mutable reference-type fixture properties.
        changed.viewModel.afterLoad = { withUnsafeCurrentTask { $0?.cancel() } }
        await Task { await changed.loadMoreAfterMetadataResolution() }.value
        precondition(changed.viewModel.requests == 1, "A changed view request must stop the old paging loop")

        let failed = PaginationFixture()
        failed.viewModel.failNext = true
        await failed.loadMoreAfterMetadataResolution()
        precondition(failed.viewModel.requests == 1 && failed.viewModel.errorMessage != nil)

        let stalled = PaginationFixture()
        stalled.viewModel.makeNoProgress = true
        await stalled.loadMoreAfterMetadataResolution()
        precondition(stalled.viewModel.requests == 1, "A no-op must not spin or repeatedly request a page")

        let reloading = PaginationFixture()
        reloading.viewModel.isReloading = true
        await reloading.loadMoreAfterMetadataResolution()
        precondition(reloading.viewModel.requests == 0)

        let cancelled = PaginationFixture()
        cancelled.viewModel.cancelNext = true
        await Task { await cancelled.loadMoreAfterMetadataResolution() }.value
        precondition(cancelled.viewModel.requests == 1, "Cancellation must stop sparse-page advancement")
    }
}

struct FileFilters: Equatable {
    var serverOrderBy: [String]? = ["size"]
    var serverOrder = "asc"
    var serverMediaTypes: [String]? = nil
    func serverHandlesMedia(_ source: Source) -> Bool { false }
}
struct Source { let supportedServerOrdering = ["name", "size"] }

@MainActor final class SortModel {
    let source = Source()
    var orderBy = ["name"]
    var order = "asc"
    var mediaTypes: [String] = []
    var loadedOnce = true
    var isReloading = false
    var isInitialLoading = false
    var cursor: String? = "old-name-cursor"
    var reloads = 0
    // PRODUCTION_SORT
    func reload(sortedBy filters: FileFilters, forceNetwork: Bool, refreshCount: Bool) async {
        precondition(forceNetwork && !refreshCount)
        reloads += 1
        applySort(filters)
        cursor = nil
    }
    func loadIfNeeded() async {} // The already-loaded, fresh-directory branch is a no-op.
}

enum Phase { case active, background }
@MainActor final class ActivationFixture {
    var isActive = true
    var scenePhase = Phase.active
    var filters = FileFilters()
    let viewModel = SortModel()
    func activate() async {
        // PRODUCTION_ACTIVATION
    }
    func check() async {
        await activate()
        precondition(viewModel.reloads == 1 && viewModel.cursor == nil,
                     "Reactivation with a changed sort must discard the old first page and cursor")
        precondition(viewModel.orderBy == ["size"])
        await viewModel.syncSort(with: filters)
        await activate()
        precondition(viewModel.reloads == 1, "The same sort must not trigger another reload")
        let fresh = ActivationFixture()
        fresh.viewModel.loadedOnce = false
        await fresh.activate()
        precondition(fresh.viewModel.orderBy == ["size"] && fresh.viewModel.reloads == 0,
                     "A new model should be configured before its initial load")
        let hidden = ActivationFixture()
        hidden.scenePhase = .background
        await hidden.activate()
        precondition(hidden.viewModel.reloads == 0 && hidden.viewModel.orderBy == ["name"])
    }
}

@MainActor final class PagingState {
    var task: Task<Void, Never>?
    var requestID: UUID?
    var replay = false
    var pending: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    var oldWasCancelled = false
}

@MainActor struct PagingRequestFixture {
    let state: PagingState
    let viewModel: PageModel
    let filter: String
    var paginationTask: Task<Void, Never>? {
        get { state.task }
        nonmutating set { state.task = newValue }
    }
    var paginationRequestID: UUID? {
        get { state.requestID }
        nonmutating set { state.requestID = newValue }
    }
    var paginationReplayPending: Bool {
        get { state.replay }
        nonmutating set { state.replay = newValue }
    }
    // PRODUCTION_REQUESTS
    private func loadMoreAfterMetadataResolution() async {
        state.calls.append(filter)
        if filter == "old" {
            viewModel.isLoadingMore = true
            await withCheckedContinuation { state.pending = $0 }
            state.oldWasCancelled = Task.isCancelled
            viewModel.isLoadingMore = false
        } else {
            precondition(!viewModel.isLoadingMore, "Replay must wait for the old request to finish")
        }
    }
    static func check() async {
        let state = PagingState()
        let model = PageModel()
        let old = PagingRequestFixture(state: state, viewModel: model, filter: "old")
        old.requestMoreFiles()
        while state.pending == nil { await Task.yield() }
        let oldTask = state.task!
        let changed = PagingRequestFixture(state: state, viewModel: model, filter: "intermediate")
        changed.restartPaginationIfNeeded()
        let latest = PagingRequestFixture(state: state, viewModel: model, filter: "latest")
        latest.restartPaginationIfNeeded()
        let replay = state.task!
        precondition(state.calls == ["old"])
        state.pending!.resume()
        await replay.value
        await oldTask.value
        precondition(state.oldWasCancelled)
        precondition(state.calls == ["old", "latest"], "Only the latest value-captured view may replay the lost demand")
        precondition(state.task == nil && state.requestID == nil)
        latest.restartPaginationIfNeeded()
        precondition(state.task == nil, "Changing a filter without a paging demand must not fetch pages")

        model.isReloading = true
        state.replay = true
        latest.restartPaginationIfNeeded()
        precondition(state.replay && state.task == nil, "A pending reload must retain the demand for its completion")
        latest.cancelPagination()
        precondition(!state.replay && state.task == nil)
    }
}

@main struct AuditBugFixChecks {
    @MainActor static func main() async {
        await PaginationFixture().check()
        await ActivationFixture().check()
        await PagingRequestFixture.check()
        print("PASS: sparse filtered pagination, termination and directory sort reactivation")
    }
}
