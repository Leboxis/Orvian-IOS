import Foundation

/// Ordre personnalisé des tags de l'onglet Tag, mémorisé par drive.
/// Défini depuis le bouton crayon (flèches haut/bas) et conservé entre les
/// sessions ; tant qu'aucun réarrangement n'a été fait, l'ordre du serveur
/// s'applique.
enum TagOrderStore {
    private static let defaults = UserDefaults.standard

    /// Identifiants dans l'ordre choisi ; nil si aucun réarrangement.
    static func order(for driveId: Int) -> [Int]? {
        guard let ids = defaults.array(forKey: key(driveId: driveId)) as? [Int] else { return nil }
        return ids.isEmpty ? nil : ids
    }

    static func save(_ ids: [Int], driveId: Int) {
        defaults.set(ids, forKey: key(driveId: driveId))
    }

    private static func key(driveId: Int) -> String {
        "tag-order-\(driveId)"
    }
}
