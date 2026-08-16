import UIKit

/// Cache disque des miniatures (`Library/Caches`), plafonné avec purge LRU.
struct DiskImageCache {
    private let root: URL
    private let maxBytes = 250 * 1024 * 1024
    private let markerSuffix = ".none"

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        root = base
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(driveId: Int, fileId: Int, pixels: Int, marker: Bool = false) -> URL {
        root
            .appendingPathComponent("\(driveId)", isDirectory: true)
            .appendingPathComponent("\(fileId)-\(pixels).jpg\(marker ? markerSuffix : "")")
    }

    // MARK: - Lecture / écriture

    func hasEntry(driveId: Int, fileId: Int, pixels: Int) -> Bool {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels)
        if FileManager.default.fileExists(atPath: fileURL.path) { return true }
        return FileManager.default.fileExists(atPath: fileURL.path + markerSuffix)
    }

    func loadImage(driveId: Int, fileId: Int, pixels: Int) -> UIImage? {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        touch(fileURL)
        return UIImage(data: data)
    }

    func store(image: UIImage, driveId: Int, fileId: Int, pixels: Int) {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
            evictIfNeeded()
        } catch {
            // Disque plein : on vit sans cache disque pour cette entrée.
        }
    }

    /// Mémorise « ce fichier n'a pas de miniature » (zéro octet).
    func storeMarker(driveId: Int, fileId: Int, pixels: Int) {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels, marker: true)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    }

    // MARK: - Maintenance

    func purge() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func totalSize() -> Int {
        guard let files = allFiles() else { return 0 }
        return files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: - Internes

    private func allFiles() -> [URL]? {
        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.hasDirectoryPath { continue }
            files.append(url)
        }
        return files
    }

    private func touch(_ fileURL: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
    }

    /// Purge LRU quand le plafond est dépassé.
    private func evictIfNeeded() {
        guard let files = allFiles() else { return }
        var entries: [(url: URL, date: Date, size: Int)] = files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > maxBytes else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}
