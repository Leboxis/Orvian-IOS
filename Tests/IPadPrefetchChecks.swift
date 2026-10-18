import Foundation

/// A manually released delay exercises the production worker without timing assertions.
actor PrefetchDelay {
    static let shared = PrefetchDelay()
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    var count: Int { pending.count }
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func release() {
        let waiters = pending.values
        pending.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

extension FileGridView {
    @MainActor
    static func checkPrefetch() async {
        let grid = FileGridView()
        let files = (0..<100).map { DriveFile(id: $0) }
        let provider = ThumbnailProvider.shared
        grid.columns = Array(repeating: 0, count: 8)
        grid.appeared(file: files[0], index: 0, in: files)
        await waitUntil { await PrefetchDelay.shared.count == 1 }
        grid.appeared(file: files[10], index: 10, in: files)
        await PrefetchDelay.shared.release()
        await grid.prefetchTask?.value
        let rows = await provider.requests
        precondition(rows == [Array(11...18)], "Only the latest position and one iPad row should be prefetched")

        grid.presentation = .list
        grid.appeared(file: files[20], index: 20, in: files)
        await waitUntil { await PrefetchDelay.shared.count == 1 }
        await PrefetchDelay.shared.release()
        await grid.prefetchTask?.value
        let listRows = await provider.requests
        precondition(listRows.last == [21, 22, 23], "List mode retains its small window")

        grid.appeared(file: files[30], index: 30, in: files)
        await waitUntil { await PrefetchDelay.shared.count == 1 }
        NetworkMonitor.shared.allowsBackgroundPrefetch = false
        await PrefetchDelay.shared.release()
        await grid.prefetchTask?.value
        let afterNetworkChange = await provider.requests
        precondition(afterNetworkChange.count == 2, "Wi-Fi-only policy must be checked after the delay")
        NetworkMonitor.shared.allowsBackgroundPrefetch = true

        grid.appeared(file: files[40], index: 40, in: files)
        await waitUntil { await PrefetchDelay.shared.count == 1 }
        let oldTask = grid.prefetchTask
        oldTask?.cancel()
        grid.prefetchTask = nil
        grid.prefetchRequestID = nil
        grid.pendingPrefetch = nil
        grid.appeared(file: files[50], index: 50, in: files)
        let newID = grid.prefetchRequestID
        await oldTask?.value
        precondition(grid.prefetchRequestID == newID && grid.prefetchTask != nil,
                     "A disappearing worker must not clear its replacement")
        await waitUntil { await PrefetchDelay.shared.count == 1 }
        await PrefetchDelay.shared.release()
        await grid.prefetchTask?.value
        let finalRows = await provider.requests
        precondition(finalRows.last == [51, 52, 53])
        print("Latest-position, adaptive-row, Wi-Fi and prefetch lifecycle checks passed")
    }

    private static func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, "Prefetch worker did not settle")
            await Task.yield()
        }
    }
}

@main struct IPadPrefetchChecks {
    static func main() async { await FileGridView.checkPrefetch() }
}
