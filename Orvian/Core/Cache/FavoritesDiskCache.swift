import Foundation
import CryptoKit

/// Cache disque historique des favoris, également réutilisé pour le petit
/// aperçu des fichiers récents. Les I/O et le codage JSON restent hors du
/// thread principal. La file série ordonne aussi écritures et purge de logout.
final class FavoritesDiskCache {
    static let shared = FavoritesDiskCache()

    private let queue = DispatchQueue(label: "com.orvian.favorites-cache", qos: .utility)
    private let directory: DiskDirectory
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let maximumFileSize = 2 * 1024 * 1024
    private let maximumTotalSize = 10 * 1024 * 1024

    private struct Entry: Codable {
        let version: Int
        let key: String
        let snapshot: DirectoryListSnapshot
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrvianFavorites", isDirectory: true)
        self.directory = DiskDirectory(root: base)
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
                    self.directory.remove(url)
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
                self.directory.remove(url)
                return
            }
            guard self.directory.write(data, to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) else {
                // Cache failures must never turn a successful API load into an error.
                return
            }
            self.evictIfNeeded()
        }
    }

    func clear() {
        queue.async { self.directory.purge() }
    }

    private func fileURL(key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.url(hash).appendingPathExtension("json")
    }

    private func evictIfNeeded() {
        let files = directory.entries().sorted { $0.date > $1.date }
        var total = 0
        for (index, file) in files.enumerated() {
            total += file.size
            if index >= 20 || total > maximumTotalSize || Date().timeIntervalSince(file.date) >= maximumAge {
                directory.remove(file.url)
            }
        }
    }
}
