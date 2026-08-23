import UIKit

/// Cache disque des miniatures (`Library/Caches`), thread-safe avec éviction FIFO (Oldest-Written-First) en arrière-plan.
///
/// L'éviction est déclenchée sur une limite choisie dans Réglages et purge
/// les plus anciens fichiers jusqu'à 80 % de cette limite.
final class DiskImageCache: @unchecked Sendable {
    private let root: URL

    private let lock = NSLock()
    private var estimatedDiskSize: Int = 0
    private var isSizeInitialized = false
    private var isEvicting = false
    /// Une seule mesure disque à la fois ; jamais pendant que le verrou est détenu.
    private var isScanning = false
    /// Invalide le résultat d'une mesure lancée avant un `purge()`.
    private var purgeGeneration = 0
    private var writeCountSinceScan = 0
    private let scanIntervalWrites = 150

    private var highWaterMark: Int {
        let limitMB = UserDefaults.standard.object(forKey: "thumbnailCacheLimitMB") as? Int ?? 250
        guard limitMB > 0 else { return .max }
        return limitMB * 1024 * 1024
    }

    private var lowWaterMark: Int {
        Int(Double(highWaterMark) * 0.8)
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        root = base
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(driveId: Int, fileId: Int, pixels: Int) -> URL {
        root
            .appendingPathComponent("\(driveId)", isDirectory: true)
            .appendingPathComponent("\(fileId)-\(pixels).jpg")
    }

    // MARK: - Lecture / écriture

    func hasEntry(driveId: Int, fileId: Int, pixels: Int) -> Bool {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels)
        // Les anciens marqueurs `.none` ne sont plus pris en compte : un 404
        // juste après un upload pouvait être temporaire et ne doit jamais
        // condamner définitivement la miniature sur les versions suivantes.
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func loadImage(driveId: Int, fileId: Int, pixels: Int) -> UIImage? {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        guard !data.isEmpty, let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    /// Retire une entrée illisible afin qu'elle ne bloque jamais un nouveau
    /// téléchargement de miniature valide.
    func removeEntry(driveId: Int, fileId: Int, pixels: Int) {
        let fileURL = url(driveId: driveId, fileId: fileId, pixels: pixels)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard (try? FileManager.default.removeItem(at: fileURL)) != nil else { return }
        lock.lock()
        if isSizeInitialized {
            estimatedDiskSize = max(0, estimatedDiskSize - size)
        }
        lock.unlock()
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

    // MARK: - Maintenance

    func purge() {
        lock.lock()
        defer { lock.unlock() }
        estimatedDiskSize = 0
        isSizeInitialized = true
        writeCountSinceScan = 0
        purgeGeneration &+= 1
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func totalSize() -> Int {
        // L'énumération récursive peut être lente : elle ne doit pas bloquer
        // les écritures/évictions concurrentes sous verrou.
        let size = computeDiskSize()
        lock.lock()
        estimatedDiskSize = size
        isSizeInitialized = true
        lock.unlock()
        return size
    }

    /// Applique immédiatement une nouvelle limite, notamment après sa
    /// modification dans les réglages.
    func enforceSizeLimit() {
        refreshEstimatedSize()
    }

    // MARK: - Gestion de la taille et éviction

    private func onFileWritten(deltaSize: Int) {
        var shouldScan = false
        var shouldEvict = false

        lock.lock()
        if isSizeInitialized {
            estimatedDiskSize = max(0, estimatedDiskSize + deltaSize)
        } else {
            // Première écriture : la taille réelle sera mesurée hors verrou.
            shouldScan = true
        }

        writeCountSinceScan += 1
        if writeCountSinceScan >= scanIntervalWrites {
            writeCountSinceScan = 0
            shouldScan = true
        }
        lock.unlock()

        if shouldScan {
            refreshEstimatedSize()
            return
        }

        lock.lock()
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

    /// Recalcule la taille du cache hors verrou. Le balayage récursif de
    /// milliers de fichiers gelait auparavant toutes les opérations du cache
    /// pendant qu'il tenait le `NSLock` sur le thread appelant.
    private func refreshEstimatedSize() {
        lock.lock()
        if isScanning {
            lock.unlock()
            return
        }
        isScanning = true
        let generation = purgeGeneration
        lock.unlock()
        defer {
            lock.lock()
            isScanning = false
            lock.unlock()
        }

        let size = computeDiskSize()

        var shouldEvict = false
        lock.lock()
        // Une purge survenue pendant la mesure invalide son résultat.
        if purgeGeneration == generation {
            estimatedDiskSize = size
            isSizeInitialized = true
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
