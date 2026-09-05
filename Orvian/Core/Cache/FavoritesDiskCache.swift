import Foundation
import CryptoKit

/// File IO and JSON coding stay off the main thread. The serial queue also
/// orders writes and logout purges so an older write cannot undo a purge.
final class FavoritesDiskCache {
    static let shared = FavoritesDiskCache()

    private let queue = DispatchQueue(label: "com.orvian.favorites-cache", qos: .utility)
    private let directory: URL
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let maximumFileSize = 2 * 1024 * 1024
    private let maximumTotalSize = 10 * 1024 * 1024

    private struct Entry: Codable {
        let version: Int
        let key: String
        let snapshot: DirectoryListSnapshot
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrvianFavorites", isDirectory: true)
    }

    func snapshot(key: String) async -> DirectoryListSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                let url = self.fileURL(key: key)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= self.maximumFileSize,
                      let data = try? Data(contentsOf: url),
                      let entry = try? JSONDecoder().decode(Entry.self, from: data),
                      entry.version == 1, entry.key == key,
                      Date().timeIntervalSince(entry.snapshot.fetchedAt) < self.maximumAge
                else {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: entry.snapshot)
            }
        }
    }

    func store(_ snapshot: DirectoryListSnapshot, key: String) {
        queue.async {
            let url = self.fileURL(key: key)
            guard let data = try? JSONEncoder().encode(Entry(version: 1, key: key, snapshot: snapshot)),
                  data.count <= self.maximumFileSize else {
                // Do not leave an older snapshot behind if this one is too large.
                try? FileManager.default.removeItem(at: url)
                return
            }
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                self.evictIfNeeded()
            } catch {
                // Cache failures must never turn a successful API load into an error.
            }
        }
    }

    func clear() {
        queue.async { try? FileManager.default.removeItem(at: self.directory) }
    }

    private func fileURL(key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }

    private func evictIfNeeded() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        let files = urls.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
        var total = 0
        for (index, file) in files.enumerated() {
            total += file.size
            if index >= 20 || total > maximumTotalSize || Date().timeIntervalSince(file.date) >= maximumAge {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }
}
