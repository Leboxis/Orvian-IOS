import UIKit

/// Cache disque des miniatures (`Library/Caches`), thread-safe avec éviction FIFO (Oldest-Written-First) en arrière-plan.
///
/// L'éviction est déclenchée sur un seuil de taille haute (highWaterMark = 250 Mo)
/// et purge les plus anciens fichiers écrits jusqu'au seuil bas (lowWaterMark = 200 Mo).
final class DiskImageCache: @unchecked Sendable {
    private let root: URL
    private let highWaterMark = 250 * 1024 * 1024 // 250 Mo
    private let lowWaterMark = 200 * 1024 * 1024  // 200 Mo (hystérésis de 50 Mo)
    private let markerSuffix = ".none"

    private let lock = NSLock()
    private var estimatedDiskSize: Int = 0
    private var isSizeInitialized = false
    private var isEvicting = false
    private var writeCountSinceScan = 0
    private let scanIntervalWrites = 150

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
        guard !data.isEmpty, let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    /// Enregistre directement les données brutes reçues du réseau (JPEG, PNG, WebP...) sans ré-encodage CPU.
    /// Utilise Data.write(options: .atomic) pour garantir qu'aucun fichier incomplet ne peut être lu.
    func store(data: Data, driveId: Int, fileId: Int, pixels: Int) {
        guard !data.isEmpty else { return }
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels)
        let oldSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
            let delta = data.count - oldSize
            onFileWritten(deltaSize: delta)
        } catch {
            // Disque plein ou permissions : on continue sans cache disque pour cette entrée.
        }
    }

    /// Rétrocompatibilité : encode un UIImage si les données brutes ne sont pas fournies.
    func store(image: UIImage, driveId: Int, fileId: Int, pixels: Int) {
        guard let data = image.jpegData(compressionQuality: 0.85) ?? image.pngData() else { return }
        store(data: data, driveId: driveId, fileId: fileId, pixels: pixels)
    }

    /// Mémorise « ce fichier n'a pas de miniature » (zéro octet).
    func storeMarker(driveId: Int, fileId: Int, pixels: Int) {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels, marker: true)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    }

    // MARK: - Maintenance

    func purge() {
        lock.lock()
        defer { lock.unlock() }
        estimatedDiskSize = 0
        isSizeInitialized = true
        writeCountSinceScan = 0
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func totalSize() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let size = computeDiskSize()
        estimatedDiskSize = size
        isSizeInitialized = true
        return size
    }

    // MARK: - Gestion de la taille et éviction

    private func onFileWritten(deltaSize: Int) {
        var shouldEvict = false

        lock.lock()
        if !isSizeInitialized {
            estimatedDiskSize = computeDiskSize()
            isSizeInitialized = true
        } else {
            estimatedDiskSize = max(0, estimatedDiskSize + deltaSize)
        }

        writeCountSinceScan += 1
        if writeCountSinceScan >= scanIntervalWrites {
            writeCountSinceScan = 0
            estimatedDiskSize = computeDiskSize()
        }

        if estimatedDiskSize > highWaterMark && !isEvicting {
            isEvicting = true
            shouldEvict = true
        }
        lock.unlock()

        if shouldEvict {
            Task.detached(priority: .utility) { [weak self] in
                self?.evictOldestFiles()
            }
        }
    }

    private func computeDiskSize() -> Int {
        guard let files = allFiles() else { return 0 }
        return files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

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

    /// Éviction FIFO / Oldest-Written-First : supprime les fichiers les plus anciens
    /// jusqu'à revenir sous le seuil bas (lowWaterMark).
    private func evictOldestFiles() {
        guard let files = allFiles() else {
            lock.lock()
            isEvicting = false
            lock.unlock()
            return
        }

        var entries: [(url: URL, date: Date, size: Int)] = files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }

        var currentTotal = entries.reduce(0) { $0 + $1.size }
        var bytesDeleted = 0

        if currentTotal > highWaterMark {
            entries.sort { $0.date < $1.date }

            for entry in entries {
                guard currentTotal > lowWaterMark else { break }
                if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                    currentTotal -= entry.size
                    bytesDeleted += entry.size
                }
            }
        }

        lock.lock()
        // Déduit exactement les octets supprimés sans écraser les écritures concurrentes survenues pendant l'éviction
        estimatedDiskSize = max(0, estimatedDiskSize - bytesDeleted)
        isEvicting = false
        lock.unlock()
    }
}
