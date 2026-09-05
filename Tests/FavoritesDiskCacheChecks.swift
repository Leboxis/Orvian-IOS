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
        print("Favorites disk cache checks passed")
    }
}
