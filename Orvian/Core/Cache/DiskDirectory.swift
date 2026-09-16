import Foundation

/// Un fichier présent dans un répertoire de cache, avec les métadonnées
/// nécessaires à l'éviction (taille, date de dernière modification).
struct DiskEntry {
    let url: URL
    let size: Int
    let date: Date
    let generation: Int
}

/// Répertoire de cache sur disque : création, écriture atomique, suppression
/// comptabilisée et énumération des fichiers avec leurs métadonnées.
///
/// Les deux caches disque de l'app (`DiskImageCache` pour les miniatures,
/// `FavoritesDiskCache` pour les listes persistées) partageaient ce même
/// socle, recopié de part et d'autre. Ce type en est désormais l'unique
/// implémentation ; chaque cache conserve en propre sa politique d'éviction.
final class DiskDirectory: @unchecked Sendable {
    private let mutationLock = NSRecursiveLock()
    private var generation = 0
    let root: URL

    init(root: URL) {
        self.root = root
        createIfNeeded()
    }

    /// Crée le répertoire racine s'il n'existe pas (idempotent).
    func createIfNeeded() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Chemin d'une entrée relative à la racine. Les composants séparés par
    /// `/` sont interprétés comme des sous-dossiers, explicitement (sans
    /// dépendre du traitement du `/` par `appendingPathComponent`).
    func url(_ relativePath: String) -> URL {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Écrit les données, en créant le dossier parent si besoin. Renvoie
    /// `false` si l'écriture a échoué (disque plein, permissions...).
    @discardableResult
    func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: options)) != nil
    }

    /// Supprime un fichier. Renvoie sa taille s'il a bien été supprimé,
    /// `nil` sinon (fichier absent ou suppression refusée).
    @discardableResult
    func remove(_ url: URL, expectedGeneration: Int? = nil) -> Int? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        if let expectedGeneration, expectedGeneration != generation { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return nil }
        return size
    }

    /// Liste récursive des fichiers du répertoire, avec taille et date.
    func entries() -> [DiskEntry] {
        mutationLock.lock()
        let scannedGeneration = generation
        mutationLock.unlock()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [DiskEntry] = []
        for case let url as URL in enumerator {
            if url.hasDirectoryPath { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            result.append(DiskEntry(
                url: url,
                size: values?.fileSize ?? 0,
                date: values?.contentModificationDate ?? .distantPast,
                generation: scannedGeneration
            ))
        }
        return result
    }

    func totalByteCount() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Renomme seulement le dossier sous verrou ; le grand ménage ne bloque
    /// ni les écritures du nouveau cache ni l'acteur des miniatures.
    func purge() {
        mutationLock.lock()
        let discarded = root.deletingLastPathComponent()
            .appendingPathComponent(".orvian-purge-\(UUID().uuidString)")
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.moveItem(at: root, to: discarded)
            }
            generation &+= 1
            createIfNeeded()
            mutationLock.unlock()
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: discarded)
            }
        } catch {
            mutationLock.unlock()
            // Une purge refusée laisse le cache intact ; aucun effacement
            // récursif de repli sur le thread appelant.
        }
    }
}
