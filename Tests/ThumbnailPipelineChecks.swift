import Foundation

extension SharedRequests {
    func subscriberCount(for key: Key) -> Int { requests[key]?.waiters.count ?? 0 }
}

extension ThumbnailProvider {
    func subscriberCount(fileId: Int) async -> Int {
        await requests.subscriberCount(for: Self.key(driveId: 1, fileId: fileId, isTrashed: false))
    }
}

actor ThumbnailTestServer {
    static let shared = ThumbnailTestServer()
    private var counts: [Int: Int] = [:]
    private var pending: [Int: (UUID, CheckedContinuation<Data, Error>)] = [:]
    private var cancelled: Set<Int> = []

    func data(fileId: Int) async throws -> Data {
        let id = UUID()
        counts[fileId, default: 0] += 1
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending[fileId] = (id, $0) }
        } onCancel: {
            Task { await self.cancel(fileId: fileId, id: id) }
        }
    }

    private func cancel(fileId: Int, id: UUID) {
        guard pending[fileId]?.0 == id else { return }
        cancelled.insert(fileId)
        pending.removeValue(forKey: fileId)?.1.resume(throwing: CancellationError())
    }

    func complete(_ fileId: Int) { pending.removeValue(forKey: fileId)?.1.resume(returning: Data([1])) }
    func count(_ fileId: Int) -> Int { counts[fileId, default: 0] }
    func wasCancelled(_ fileId: Int) -> Bool { cancelled.contains(fileId) }
    var pendingCount: Int { pending.count }
}

@main
struct ThumbnailPipelineChecks {
    static func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, "Thumbnail request did not settle")
            await Task.yield()
        }
    }

    static func main() async {
        let provider = ThumbnailProvider()
        let server = ThumbnailTestServer.shared
        let first = Task { await provider.thumbnail(driveId: 1, fileId: 42) }
        await waitUntil { await server.count(42) == 1 }
        let second = Task { await provider.thumbnail(driveId: 1, fileId: 42) }
        await waitUntil { await provider.subscriberCount(fileId: 42) == 2 }
        first.cancel()
        let cancelledImage = await first.value
        precondition(cancelledImage == nil)
        let remaining = await provider.subscriberCount(fileId: 42)
        let stoppedEarly = await server.wasCancelled(42)
        precondition(remaining == 1 && !stoppedEarly, "The other visible card must retain its request")
        await server.complete(42)
        let image = await second.value
        precondition(image != nil && provider.cachedMemoryThumbnail(driveId: 1, fileId: 42, isTrashed: false) != nil)
        let duplicateCount = await server.count(42)
        precondition(duplicateCount == 1)

        let last = Task { await provider.thumbnail(driveId: 1, fileId: 43) }
        await waitUntil { await server.count(43) == 1 }
        last.cancel()
        let abandonedImage = await last.value
        precondition(abandonedImage == nil)
        await waitUntil { await server.wasCancelled(43) }
        let replacement = Task { await provider.thumbnail(driveId: 1, fileId: 43) }
        await waitUntil { await server.count(43) == 2 }
        await server.complete(43)
        let replacementImage = await replacement.value
        precondition(replacementImage != nil, "Cancellation must not poison the negative cache")

        await provider.prefetch(driveId: 1, fileIds: [44])
        await waitUntil { await server.count(44) == 1 }
        let visible = Task { await provider.thumbnail(driveId: 1, fileId: 44) }
        await waitUntil { await provider.subscriberCount(fileId: 44) == 2 }
        await provider.cancelPrefetch()
        await waitUntil { await provider.subscriberCount(fileId: 44) == 1 }
        await server.complete(44)
        let visibleImage = await visible.value
        precondition(visibleImage != nil, "Cancelling prefetch must preserve its visible subscriber")

        // Saturate all permits, abandon a queued card, then reveal a new one.
        let occupied = (100..<108).map { id in Task { await provider.thumbnail(driveId: 1, fileId: id) } }
        await waitUntil { await server.pendingCount == 8 }
        let queued = Task { await provider.thumbnail(driveId: 1, fileId: 108) }
        await waitUntil { await provider.subscriberCount(fileId: 108) == 1 }
        queued.cancel()
        _ = await queued.value
        let newest = Task { await provider.thumbnail(driveId: 1, fileId: 109) }
        await server.complete(100)
        await waitUntil { await server.count(109) == 1 }
        let obsoleteCount = await server.count(108)
        precondition(obsoleteCount == 0, "An abandoned queued card must never start a download")
        occupied.forEach { $0.cancel() }
        newest.cancel()
        for task in occupied { _ = await task.value }
        _ = await newest.value
        await waitUntil { await server.pendingCount == 0 }
        print("Thumbnail subscriber cancellation, cache reuse and obsolete queue checks passed")
    }
}
