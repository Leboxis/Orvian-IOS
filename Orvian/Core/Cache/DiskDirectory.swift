import Foundation

/// Un fichier présent dans un répertoire de cache, avec les métadonnées
/// nécessaires à l'éviction (taille, date de dernière modification).
struct DiskEntry {
    let url: URL
    let size: Int
    let date: Date
}

/// Répertoire de cache sur disque : création, écriture atomique, suppression
/// comptabilisée et énumération des fichiers avec leurs métadonnées.
///
/// Les deux caches disque de l'app (`DiskImageCache` pour les miniatures,
/// `FavoritesDiskCache` pour les listes persistées) partageaient ce même
/// socle, recopié de part et d'autre. Ce type en est désormais l'unique
/// implémentation ; chaque cache conserve en propre sa politique d'éviction.
final class DiskDirectory {
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
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: options)) != nil
    }

    /// Supprime un fichier. Renvoie sa taille s'il a bien été supprimé,
    /// `nil` sinon (fichier absent ou suppression refusée).
    @discardableResult
    func remove(_ url: URL) -> Int? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return nil }
        return size
    }

    /// Liste récursive des fichiers du répertoire, avec taille et date.
    func entries() -> [DiskEntry] {
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
                date: values?.contentModificationDate ?? .distantPast
            ))
        }
        return result
    }

    func totalByteCount() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Supprime tout le contenu et recrée la racine vide.
    func purge() {
        try? FileManager.default.removeItem(at: root)
        createIfNeeded()
    }
}
