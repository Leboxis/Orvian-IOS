import Foundation

@main
struct MetadataVersionChecks {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("metadata.json")
        func entry(size: Int, modified: Double) -> [String: Any] {
            ["info": ["duration": 10, "orientation": "portrait", "maximumDimension": 1080],
             "size": size, "lastModifiedAt": modified, "resolvedAt": 0]
        }
        try JSONSerialization.data(withJSONObject: [
            "account-a-1-42": entry(size: 100, modified: 1),
            "account-a-1-43": entry(size: 100, modified: 1)
        ]).write(to: url)
        let store = MediaMetadataStore(storageURL: url)
        for id in [42, 43] {
            let original = DriveFile(id: id, size: 100, lastModifiedAt: 1)
            await store.resolveAll(driveId: 1, items: [original])
            precondition(store.info(driveId: 1, for: id)?.duration == 10)
            precondition(VideoAssetCache.shared.calls == id - 42,
                         "Persisted V1 must promote offline without creating an asset")
            // Cover each version field independently, including rejection before resolution.
            let replacement = DriveFile(id: id, size: id == 42 ? 200 : 100,
                                        lastModifiedAt: id == 43 ? 2 : 1)
            precondition(store.snapshot(driveId: 1, items: [replacement]).info(for: id) == nil,
                         "A promoted V1 must not satisfy a changed version snapshot")
            await store.resolveAll(driveId: 1, items: [replacement])
            precondition(store.info(driveId: 1, for: id) == nil,
                         "Failed V2 resolution must not leave stale V1 in memory")
            let cached = await store.cachedInfo(driveId: 1, file: replacement)
            precondition(cached == nil, "Invalidated V1 must not return through the disk fallback")
        }
        precondition(VideoAssetCache.shared.invalidations == [42, 43],
                     "Each detected replacement must invalidate its underlying AVURLAsset")

        // Exercise both completion orders; no sleeps or network access are needed.
        for oldFinishesFirst in [true, false] {
            let id = oldFinishesFirst ? 70 : 80
            let oldAssetID = id + 1
            let newAssetID = id + 2
            let original = DriveFile(id: id, size: 100, lastModifiedAt: 1)
            let replacement = DriveFile(id: id, size: 200, lastModifiedAt: 2)
            VideoAssetCache.shared.nextAsset = AVURLAsset(id: oldAssetID)
            let old = Task { await store.resolveAll(driveId: 1, items: [original]) }
            while !(await MetadataLoads.shared.contains(oldAssetID)) { await Task.yield() }
            VideoAssetCache.shared.nextAsset = AVURLAsset(id: newAssetID)
            let latest = Task { await store.resolveAll(driveId: 1, items: [replacement]) }
            while !(await MetadataLoads.shared.contains(newAssetID)) { await Task.yield() }
            if oldFinishesFirst {
                await MetadataLoads.shared.complete(oldAssetID, duration: 10)
                await old.value
                let calls = VideoAssetCache.shared.calls
                await store.resolveAll(driveId: 1, items: [replacement])
                precondition(VideoAssetCache.shared.calls == calls,
                             "Finishing V1 must not release V2's in-flight reservation")
                precondition(store.info(driveId: 1, for: id) == nil)
                await MetadataLoads.shared.complete(newAssetID, duration: 20)
                await latest.value
            } else {
                await MetadataLoads.shared.complete(newAssetID, duration: 20)
                await latest.value
                await MetadataLoads.shared.complete(oldAssetID, duration: 10)
                await old.value
            }
            precondition(store.info(driveId: 1, for: id)?.duration == 20,
                         "Stale V1 completion must never overwrite the newer V2 facts")
        }
        print("Metadata version invalidation and out-of-order completion checks passed")
    }
}
