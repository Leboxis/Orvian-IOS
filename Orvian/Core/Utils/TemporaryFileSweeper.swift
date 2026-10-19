import Foundation

/// Supprime les copies jetables laissées dans `tmp` par une session
/// précédente : photos et documents préparés pour l'import, fichiers déposés,
/// téléchargements en attente de partage et segments d'upload.
///
/// Ces fichiers sont déjà supprimés au cas par cas quand une opération se
/// termine normalement. Un import annulé, un upload échoué ou une app tuée
/// pendant la feuille de partage laissaient en revanche une copie complète
/// du fichier, jamais purgée : sur un iPhone qui importe des vidéos, cela
/// représentait plusieurs gigaoctets invisibles.
///
/// Le nettoyage tourne au lancement, quand aucune opération n'est en vol, et
/// hors du MainActor : l'énumération d'un dossier volumineux ne doit pas
/// retarder l'affichage.
enum TemporaryFileSweeper {
    /// Dossiers entièrement dédiés à des copies jetables.
    private static let ownedDirectories = ["Uploads", "DroppedFiles", "OrvianDownloads", "OrvianPreviews"]

    /// Préfixe des segments écrits par `UploadChunkReader` à la racine de `tmp`.
    private static let chunkPrefix = "orvian-chunk-"

    static func sweep() async {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let root = manager.temporaryDirectory

            for name in ownedDirectories {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                guard manager.fileExists(atPath: directory.path) else { continue }
                try? manager.removeItem(at: directory)
            }

            let entries = (try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where entry.lastPathComponent.hasPrefix(chunkPrefix) {
                try? manager.removeItem(at: entry)
            }
        }.value
    }
}
