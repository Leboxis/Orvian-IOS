import UIKit
import CryptoKit

/// Cache disque des miniatures (`Library/Caches`), thread-safe avec éviction FIFO (Oldest-Written-First) en arrière-plan.
///
/// L'éviction est déclenchée sur une limite choisie dans Réglages et purge
/// les plus anciens fichiers jusqu'à 80 % de cette limite.
final class DiskImageCache: @unchecked Sendable {
    private static let formatDirectory = "v2"
    private let directory: DiskDirectory

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
        self.directory = DiskDirectory(root: base)
        removeUnnamespacedLegacyEntries()
    }

    /// Le fingerprint est déjà non réversible aujourd'hui, mais le re-hasher
    /// ici garantit qu'aucune évolution de sa source ne place un secret brut
    /// ou un composant de chemin arbitraire dans le nom d'un fichier.
    private func credentialNamespace(_ credentialFingerprint: String) -> String {
        SHA256.hash(data: Data(credentialFingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func url(
        credentialFingerprint: String,
        driveId: Int,
        fileId: Int,
        isTrashed: Bool
    ) -> URL {
        let namespace = credentialNamespace(credentialFingerprint)
        let state = isTrashed ? "trash" : "normal"
        return directory.url("\(Self.formatDirectory)/\(namespace)/\(state)/\(driveId)/\(fileId).image")
    }

    /// Les anciens chemins `<drive>/<file>.jpg` et `-360.jpg` ne permettaient
    /// d'identifier ni le compte ni l'état corbeille. Ils sont supprimés au
    /// lieu d'être migrés vers un namespace qui serait nécessairement ambigu.
    private func removeUnnamespacedLegacyEntries() {
        let marker = directory.url("\(Self.formatDirectory)/.legacy-cleanup-complete")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let namespacedRoot = directory.url(Self.formatDirectory).standardizedFileURL.path + "/"
        var cleanupSucceeded = true
        for entry in directory.entries() where !entry.url.standardizedFileURL.path.hasPrefix(namespacedRoot) {
            if directory.remove(entry.url, expectedGeneration: entry.generation) == nil {
                cleanupSucceeded = false
            }
        }
        if cleanupSucceeded {
            _ = directory.write(Data(), to: marker)
        }
    }

    // MARK: - Lecture / écriture

    func hasEntry(
        credentialFingerprint: String,
        driveId: Int,
        fileId: Int,
        isTrashed: Bool
    ) -> Bool {
        // Les anciens marqueurs `.none` ne sont plus pris en compte : un 404
        // juste après un upload pouvait être temporaire et ne doit jamais
        // condamner définitivement la miniature sur les versions suivantes.
        FileManager.default.fileExists(atPath: url(
            credentialFingerprint: credentialFingerprint,
            driveId: driveId,
            fileId: fileId,
            isTrashed: isTrashed
        ).path)
    }

    func loadImage(
        credentialFingerprint: String,
        driveId: Int,
        fileId: Int,
        isTrashed: Bool
    ) -> UIImage? {
        let fileURL = url(
            credentialFingerprint: credentialFingerprint,
            driveId: driveId,
            fileId: fileId,
            isTrashed: isTrashed
        )
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        guard !data.isEmpty, let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    /// Retire un fichier en mettant à jour la taille estimée du cache.
    private func removeFileAndAccount(_ fileURL: URL) {
        guard let size = directory.remove(fileURL) else { return }
        lock.lock()
        if isSizeInitialized {
            estimatedDiskSize = max(0, estimatedDiskSize - size)
        }
        lock.unlock()
    }

    /// Retire une entrée illisible afin qu'elle ne bloque jamais un nouveau
    /// téléchargement de miniature valide.
    func removeEntry(
        credentialFingerprint: String,
        driveId: Int,
        fileId: Int,
        isTrashed: Bool
    ) {
        removeFileAndAccount(url(
            credentialFingerprint: credentialFingerprint,
            driveId: driveId,
            fileId: fileId,
            isTrashed: isTrashed
        ))
    }

    /// Enregistre directement les données brutes reçues du réseau (JPEG, PNG, WebP...) sans ré-encodage CPU.
    /// Utilise Data.write(options: .atomic) pour garantir qu'aucun fichier incomplet ne peut être lu.
    func store(
        data: Data,
        credentialFingerprint: String,
        driveId: Int,
        fileId: Int,
        isTrashed: Bool
    ) {
        guard !data.isEmpty else { return }
        let fileURL = url(
            credentialFingerprint: credentialFingerprint,
            driveId: driveId,
            fileId: fileId,
            isTrashed: isTrashed
        )
        let oldSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard directory.write(data, to: fileURL) else {
            // Disque plein ou permissions : on continue sans cache disque pour cette entrée.
            return
        }
        onFileWritten(deltaSize: data.count - oldSize)
    }

    // MARK: - Maintenance

    func purge() {
        lock.lock()
        defer { lock.unlock() }
        estimatedDiskSize = 0
        isSizeInitialized = true
        writeCountSinceScan = 0
        purgeGeneration &+= 1
        directory.purge()
    }

    func totalSize() -> Int {
        // L'énumération récursive peut être lente : elle ne doit pas bloquer
        // les écritures/évictions concurrentes sous verrou.
        let size = directory.totalByteCount()
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

        let size = directory.totalByteCount()

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

    /// Éviction FIFO / Oldest-Written-First : supprime les fichiers les plus anciens
    /// jusqu'à revenir sous le seuil bas (lowWaterMark).
    private func evictOldestFiles() {
        var entries = directory.entries()
        var currentTotal = entries.reduce(0) { $0 + $1.size }
        var bytesDeleted = 0

        if currentTotal > highWaterMark {
            entries.sort { $0.date < $1.date }

            for entry in entries {
                guard currentTotal > lowWaterMark else { break }
                if let size = directory.remove(entry.url, expectedGeneration: entry.generation) {
                    currentTotal -= size
                    bytesDeleted += size
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
