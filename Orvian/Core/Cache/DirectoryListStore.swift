import Foundation

/// Instantané d'une liste déjà chargée : première(s) page(s), curseur de
/// pagination, compteur du dossier et tri serveur utilisé.
struct DirectoryListSnapshot {
    var items: [DriveFile]
    var cursor: String?
    var hasMore: Bool
    var totalItemCount: Int?
    var orderBy: [String]
    var order: String
    /// Date de la lecture réseau qui a produit cet instantané : permet aux
    /// appelants de sauter la revalidation quand l'entrée est encore fraîche
    /// (les endpoints coûteux comme `last_modified` ne doivent pas repartir
    /// à chaque bascule d'onglet).
    var fetchedAt: Date = Date()
}

/// Mémoire des listings déjà consultés (dossiers, favoris, recents, tag,
/// corbeille), conservée le temps de la session. Une réouverture affiche
/// l'instantané immédiatement ; le view-model revalide ensuite le réseau
/// en arrière-plan (ETag → 304 si rien n'a changé) et resynchronise
/// l'entrée à chaque mutation locale (corbeille, déplacement, import…).
///
/// Rien n'est écrit sur disque : au lancement, l'app repart du cache HTTP
/// comme avant. Les sources de recherche ne sont pas mémorisées (espace
/// de clés trop vaste pour leur réutilisation).
@MainActor
final class DirectoryListStore {
    static let shared = DirectoryListStore()

    /// Au-delà de cette durée, l'entrée n'est plus servie : la grille
    /// repart du réseau et du squelette, comme sans cache.
    private let ttl: TimeInterval = 5 * 60
    /// Plafond d'entrées ; au-delà, les plus anciennes sont éjectées.
    private let capacity = 50

    private var entries: [String: DirectoryListSnapshot] = [:]
    private var dates: [String: Date] = [:]

    private init() {}

    /// Clé de cache : drive + source + tri serveur courant. Un changement
    /// de tri relit une autre clé ; le retour au tri par défaut retrouve
    /// l'instantané d'origine. `nil` pour les sources non mémorisées.
    static func cacheKey(source: FileSource, driveId: Int, orderBy: [String], order: String) -> String? {
        let ordering = "\(orderBy.joined(separator: ","))|\(order)"
        switch source {
        case let .directory(directoryId):
            return "\(driveId)|dir|\(directoryId)|\(ordering)"
        case let .favorites(limit):
            return "\(driveId)|fav|\(limit)|\(ordering)"
        case let .recents(limit):
            return "\(driveId)|rec|\(limit)|\(ordering)"
        case let .category(categoryId):
            return "\(driveId)|cat|\(categoryId)|\(ordering)"
        case .trash:
            return "\(driveId)|trash|\(ordering)"
        case .search:
            return nil
        }
    }

    /// Instantané servi s'il existe et n'a pas dépassé le TTL.
    func snapshot(source: FileSource, driveId: Int, orderBy: [String], order: String) -> DirectoryListSnapshot? {
        guard let key = Self.cacheKey(source: source, driveId: driveId, orderBy: orderBy, order: order),
              let snapshot = entries[key] else { return nil }
        guard let date = dates[key], Date().timeIntervalSince(date) < ttl else {
            entries.removeValue(forKey: key)
            dates.removeValue(forKey: key)
            return nil
        }
        return snapshot
    }

    /// Âge de l'instantané mémorisé pour une clé, `nil` s'il n'existe pas ou
    /// a expiré. Les vues l'utilisent pour sauter une revalidation réseau
    /// encore inutile (pull-to-refresh et mutations restent toujours servis).
    func store(
        source: FileSource,
        driveId: Int,
        orderBy: [String],
        order: String,
        items: [DriveFile],
        cursor: String?,
        hasMore: Bool,
        totalItemCount: Int?
    ) {
        guard let key = Self.cacheKey(source: source, driveId: driveId, orderBy: orderBy, order: order) else { return }
        entries[key] = DirectoryListSnapshot(
            items: items,
            cursor: cursor,
            hasMore: hasMore,
            totalItemCount: totalItemCount,
            orderBy: orderBy,
            order: order
        )
        dates[key] = Date()
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let surplus = entries.count - capacity
        let oldestKeys = dates
            .sorted { $0.value < $1.value }
            .prefix(surplus)
            .map(\.key)
        for key in oldestKeys {
            entries.removeValue(forKey: key)
            dates.removeValue(forKey: key)
        }
    }
}
