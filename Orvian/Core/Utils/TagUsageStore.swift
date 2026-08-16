import Foundation

/// Mémorise la dernière utilisation de chaque tag (ouverture de la catégorie
/// ou application sur un fichier) pour trier l'onglet Tag du plus récent au
/// plus ancien.
enum TagUsageStore {
    private static let defaults = UserDefaults.standard

    static func markUsed(driveId: Int, categoryId: Int) {
        defaults.set(Date().timeIntervalSince1970, forKey: key(driveId: driveId, categoryId: categoryId))
    }

    /// Dernière utilisation ; nil si le tag n'a jamais été utilisé.
    static func lastUsed(driveId: Int, categoryId: Int) -> Date? {
        let timestamp = defaults.double(forKey: key(driveId: driveId, categoryId: categoryId))
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private static func key(driveId: Int, categoryId: Int) -> String {
        "tag-last-used-\(driveId)-\(categoryId)"
    }
}