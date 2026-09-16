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

    static func sorted(_ categories: [Category], order: [Int]?) -> [Category] {
        guard let order, !order.isEmpty else { return categories }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return categories.sorted {
            let lhs = rank[$0.id] ?? Int.max
            let rhs = rank[$1.id] ?? Int.max
            return lhs != rhs ? lhs < rhs : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func key(driveId: Int) -> String {
        "tag-order-\(driveId)"
    }
}
