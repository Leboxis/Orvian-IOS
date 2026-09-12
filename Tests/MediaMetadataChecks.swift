import Foundation

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
        let file = DriveFile(id: 42)
        TokenStore.credential = "account-a"
        await store.resolveAll(driveId: 1, items: [file])
        await store.resolveAll(driveId: 2, items: [file])
        precondition(store.info(driveId: 1, for: 42)?.duration == 10)
        precondition(store.info(driveId: 2, for: 42)?.duration == 20)
        TokenStore.credential = "account-b"
        precondition(store.info(driveId: 1, for: 42) == nil, "Never reuse another account's memory cache")
        await store.resolveAll(driveId: 1, items: [file])
        precondition(store.info(driveId: 1, for: 42)?.duration == 30)
        TokenStore.credential = "account-c"
        await store.resolveAll(driveId: 1, items: [file])
        precondition(store.info(driveId: 1, for: 42) == nil, "Unscoped legacy disk entries must be ignored")
        print("Media metadata isolation checks passed")
    }
}
