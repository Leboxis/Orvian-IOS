import Foundation

@main
struct FavoritesDiskCacheChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FavoritesDiskCache(directory: directory)
        var file = DriveFile.root(name: "Favori enregistré")
        file.isFavorite = true
        file.categories = [FileCategory(categoryId: 42)]
        let date = Date(timeIntervalSinceNow: -120)
        let snapshot = DirectoryListSnapshot(items: [file], cursor: "next", hasMore: true,
                                             totalItemCount: nil, orderBy: ["name"], order: "asc", fetchedAt: date)
        cache.store(snapshot, key: "account-a|drive-1")
        let saved = await cache.snapshot(key: "account-a|drive-1")
        precondition(saved?.items == [file], "Files and tags must survive JSON coding")
        precondition(saved?.cursor == "next" && saved?.hasMore == true, "Pagination must survive")
        precondition(saved?.fetchedAt == date, "Local writes must not renew network freshness")
        let reopened = FavoritesDiskCache(directory: directory)
        let restored = await reopened.snapshot(key: "account-a|drive-1")
        precondition(restored?.items == [file], "A new cache instance must restore persisted files")
        let otherAccount = await cache.snapshot(key: "account-b|drive-1")
        precondition(otherAccount == nil, "Accounts must be isolated")
        let otherDrive = await cache.snapshot(key: "account-a|drive-2")
        precondition(otherDrive == nil, "Drives must be isolated")
        var expired = snapshot
        expired.fetchedAt = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
        cache.store(expired, key: "expired")
        let old = await cache.snapshot(key: "expired")
        precondition(old == nil, "Expired data must be discarded")
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in urls { try Data("broken JSON".utf8).write(to: url) }
        let corrupt = await cache.snapshot(key: "account-a|drive-1")
        precondition(corrupt == nil, "Corruption must fall back to the network")
        cache.store(snapshot, key: "account-a|drive-1")
        cache.clear()
        let cleared = await cache.snapshot(key: "account-a|drive-1")
        precondition(cleared == nil, "Logout must remove even pending writes")
        // Une entrée trop grosse ne doit pas empêcher la conservation d'une
        // petite entrée plus ancienne qui tient encore dans le budget.
        let capacityDirectory = directory.appendingPathComponent("capacity")
        let capacityCache = FavoritesDiskCache(directory: capacityDirectory)
        let now = Date()
        func seed(_ name: String, bytes: Int, age: TimeInterval) throws -> URL {
            let url = capacityDirectory.appendingPathComponent(name)
            try Data(repeating: 0, count: bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                                   ofItemAtPath: url.path)
            return url
        }
        for index in 0..<5 { _ = try seed("recent-\(index)", bytes: 1_800_000, age: Double(index + 1)) }
        let oversized = try seed("does-not-fit", bytes: 1_800_000, age: 10)
        let small = try seed("small-older", bytes: 100_000, age: 11)
        capacityCache.store(snapshot, key: "trigger")
        _ = await capacityCache.snapshot(key: "trigger") // attend aussi l'éviction sur la file série
        precondition(!FileManager.default.fileExists(atPath: oversized.path))
        precondition(FileManager.default.fileExists(atPath: small.path), "Keep smaller older entries that fit")
        print("Favorites disk cache checks passed")
    }
}
