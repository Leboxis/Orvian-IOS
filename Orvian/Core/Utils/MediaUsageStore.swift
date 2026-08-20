import Foundation

/// Traqueur local et persistant des fichiers/médias les plus consultés.
///
/// Sauvegarde automatique dans `UserDefaults` (faible empreinte, zéro réseau, zéro consommation batterie),
/// persisté même après fermeture complète ou redémarrage de l'application.
final class MediaUsageStore {
    static let shared = MediaUsageStore()

    private let userDefaultsKey = "orvian_media_view_records"
    private let queue = DispatchQueue(label: "com.orvian.media-usage", qos: .utility)
    /// Clé `"\(driveId)-\(fileId)"` : les identifiants de fichiers ne sont
    /// garantis qu'à l'intérieur d'un drive, la clé inclut donc le drive pour
    /// ne jamais mélanger deux drives entre eux.
    private var records: [String: MediaViewRecord] = [:]

    struct MediaViewRecord: Codable, Identifiable {
        let file: DriveFile
        var count: Int
        var lastViewedAt: Double
        var id: Int { file.id }
    }

    private init() {
        loadFromDisk()
    }

    /// Enregistre une consultation pour un fichier (hors dossiers).
    static func recordView(driveId: Int, file: DriveFile) {
        guard !file.isDirectory else { return }
        shared.queue.async {
            shared.record(driveId: driveId, file: file)
        }
    }

    /// Renvoie les fichiers les plus consultés d'un drive donné.
    static func mostViewedFiles(driveId: Int, limit: Int = 12) -> [DriveFile] {
        shared.queue.sync {
            let prefix = "\(driveId)-"
            let sorted = shared.records
                .filter { $0.key.hasPrefix(prefix) }
                .map(\.value)
                .filter { !$0.file.isDirectory }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count {
                        return lhs.count > rhs.count
                    }
                    return lhs.lastViewedAt > rhs.lastViewedAt
                }

            return Array(sorted.prefix(limit).map(\.file))
        }
    }

    // MARK: - Gestion interne

    private func record(driveId: Int, file: DriveFile) {
        let key = "\(driveId)-\(file.id)"
        let now = Date().timeIntervalSince1970
        if var existing = records[key] {
            existing.count += 1
            existing.lastViewedAt = now
            records[key] = existing
        } else {
            records[key] = MediaViewRecord(file: file, count: 1, lastViewedAt: now)
        }

        // Limiter aux 200 éléments les plus pertinents pour préserver la mémoire
        if records.count > 200 {
            let sortedKeys = records.values
                .sorted { $0.count > $1.count }
                .prefix(200)
                .map { "\(driveId)-\($0.file.id)" }
            let keySet = Set(sortedKeys)
            records = records.filter { keySet.contains($0.key) }
        }

        saveToDisk()
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: MediaViewRecord].self, from: data) else {
            return
        }
        // Les clés JSON sont toujours des chaînes : les anciennes données
        // (clés = numéro de fichier seul) se décodent encore, mais leurs clés
        // sans préfixe de drive ne correspondent à aucun drive et sont donc
        // naturellement ignorées jusqu'à reconstruction.
        records = decoded
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
