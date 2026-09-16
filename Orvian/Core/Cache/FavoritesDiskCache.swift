import Foundation
import CryptoKit

/// Cache disque historique des favoris, également réutilisé pour le petit
/// aperçu des fichiers récents. Les I/O et le codage JSON restent hors du
/// thread principal. La file série ordonne aussi écritures et purge de logout.
final class FavoritesDiskCache: @unchecked Sendable {
    static let shared = FavoritesDiskCache()

    private let queue = DispatchQueue(label: "com.orvian.favorites-cache", qos: .utility)
    private let directory: DiskDirectory
    // Accès exclusivement sur queue : une rafale remplace l'instantané en
    // attente, avec au plus une écriture par clé et par seconde.
    private var pending: [String: DirectoryListSnapshot] = [:]
    private var flushScheduled = false
    private var generation = 0
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
                self.flush(key: key)
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
            self.pending[key] = snapshot
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            let generation = self.generation
            self.queue.asyncAfter(deadline: .now() + 1) {
                guard self.generation == generation else { return }
                self.flushScheduled = false
                self.flushAll()
            }
        }
    }

    /// Appelée à la mise en arrière-plan pour ne pas perdre la dernière rafale.
    func flushPending() {
        queue.async { self.flushAll() }
    }

    private func flushAll() {
        for key in Array(pending.keys) { flush(key: key) }
    }

    private func flush(key: String) {
        guard let snapshot = pending.removeValue(forKey: key) else { return }
        let url = fileURL(key: key)
        guard let data = try? JSONEncoder().encode(Entry(version: 1, key: key, snapshot: snapshot)),
              data.count <= maximumFileSize else {
            directory.remove(url)
            return
        }
        guard directory.write(data, to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) else { return }
        evictIfNeeded()
    }

    func clear() {
        queue.async {
            self.generation &+= 1
            self.pending.removeAll()
            self.flushScheduled = false
            self.directory.purge()
        }
    }

    private func fileURL(key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.url(hash).appendingPathExtension("json")
    }

    private func evictIfNeeded() {
        let files = directory.entries().sorted { $0.date > $1.date }
        var total = 0
        var kept = 0
        for file in files {
            if kept >= 20 || total + file.size > maximumTotalSize || Date().timeIntervalSince(file.date) >= maximumAge {
                directory.remove(file.url, expectedGeneration: file.generation)
            } else {
                total += file.size
                kept += 1
            }
        }
    }
}
