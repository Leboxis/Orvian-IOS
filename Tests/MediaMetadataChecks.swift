import Foundation

extension MediaMetadataStore {
    @MainActor
    func checkRevisionCoalescing() async {
        let initial = revision
        for _ in 0..<100 { scheduleRevisionUpdate() }
        precondition(revision == initial, "A burst must not publish synchronously")
        await pendingRevisionTask?.value
        precondition(revision == initial + 1, "100 notifications must share one publication")

        scheduleRevisionUpdate()
        let oldTask = pendingRevisionTask
        publishPendingRevision()
        precondition(revision == initial + 2, "The final batch must be immediately visible")
        scheduleRevisionUpdate()
        await oldTask?.value
        precondition(pendingRevisionTask != nil, "An old cancelled timer must preserve the new batch")
        await pendingRevisionTask?.value
        precondition(revision == initial + 3, "A trailing batch must publish exactly once")
    }
}

@main
struct MediaMetadataChecks {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("metadata.json")
        func entry(_ duration: Double) -> [String: Any] {
            ["info": ["duration": duration, "orientation": "landscape", "maximumDimension": 1920],
             "resolvedAt": 0]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "account-a-1-42": entry(10), "account-a-2-42": entry(20),
            "account-b-1-42": entry(30), "1-42": entry(999)
        ])
        try data.write(to: url)
        let store = MediaMetadataStore(storageURL: url)
        await store.checkRevisionCoalescing()
        let file = DriveFile(id: 42)
        TokenStore.credential = "account-a"
        let cached = await store.cachedInfo(driveId: 1, file: file)
        precondition(cached?.duration == 10 && VideoAssetCache.shared.calls == 0,
                     "Details must read disk facts without creating a video asset")
        await store.resolveAll(driveId: 1, items: [file])
        precondition(store.revision == 4, "resolveAll must flush restored facts before returning")
        await store.resolveAll(driveId: 2, items: [file])
        precondition(store.info(driveId: 1, for: 42)?.duration == 10)
        precondition(store.info(driveId: 2, for: 42)?.duration == 20)
        TokenStore.credential = "account-b"
        precondition(store.info(driveId: 1, for: 42) == nil, "Never reuse another account's memory cache")
        await store.resolveAll(driveId: 1, items: [file])
        precondition(store.info(driveId: 1, for: 42)?.duration == 30)
        TokenStore.credential = "account-c"
        let unavailable = await store.cachedInfo(driveId: 1, file: file)
        precondition(unavailable == nil && VideoAssetCache.shared.calls == 0)
        await store.resolveAll(driveId: 1, items: [file])
        precondition(store.info(driveId: 1, for: 42) == nil, "Unscoped legacy disk entries must be ignored")
        print("Media metadata isolation checks passed")
    }
}
