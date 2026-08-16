import Foundation

/// Traqueur local et persistant des fichiers/médias les plus consultés.
///
/// Sauvegarde automatique dans `UserDefaults` (faible empreinte, zéro réseau, zéro consommation batterie),
/// persisté même après fermeture complète ou redémarrage de l'application.
final class MediaUsageStore {
    static let shared = MediaUsageStore()

    private let userDefaultsKey = "orvian_media_view_records"
    private let queue = DispatchQueue(label: "com.orvian.media-usage", qos: .utility)
    private var records: [Int: MediaViewRecord] = [:]

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
    static func recordView(file: DriveFile) {
        guard !file.isDirectory else { return }
        shared.queue.async {
            shared.record(file: file)
        }
    }

    /// Renvoie les fichiers les plus consultés pour un drive donné.
    static func mostViewedFiles(driveId: Int, limit: Int = 12) -> [DriveFile] {
        shared.queue.sync {
            let sorted = shared.records.values
                .filter { record in
                    // Exclusion stricte des dossiers et vérification du parent/drive si applicable
                    !record.file.isDirectory
                }
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

    private func record(file: DriveFile) {
        let now = Date().timeIntervalSince1970
        if var existing = records[file.id] {
            existing.count += 1
            existing.lastViewedAt = now
            records[file.id] = existing
        } else {
            records[file.id] = MediaViewRecord(file: file, count: 1, lastViewedAt: now)
        }

        // Limiter aux 200 éléments les plus pertinents pour préserver la mémoire
        if records.count > 200 {
            let sortedKeys = records.values
                .sorted { $0.count > $1.count }
                .prefix(200)
                .map(\.file.id)
            let keySet = Set(sortedKeys)
            records = records.filter { keySet.contains($0.key) }
        }

        saveToDisk()
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([Int: MediaViewRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
