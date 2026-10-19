import Foundation

/// Mémorise le tri et les filtres par onglet (Accueil, Favoris, Tags).
///
/// Ils vivaient dans un `@State` remis à zéro à chaque remontage de la vue :
/// choisir « Date de modification / décroissant / vidéos » puis passer à
/// l'onglet Favoris et revenir effaçait le réglage, alors que la présentation
/// grille/liste, elle, était déjà mémorisée.
///
/// Le stockage est un simple JSON dans `UserDefaults`, à la clé de
/// l'onglet : aucune migration n'est nécessaire, une valeur absente ou
/// illisible retombe sur les réglages par défaut.
///
/// `load` est appelé depuis les `init` de `DirectoryView`, `FavoritesView` et
/// `RecentFilesView` — donc à **chaque** reconstruction de ces valeurs de vue,
/// y compris quand SwiftUI jette le résultat (l'`init` d'une vue peut être
/// réévalué sans que son `@State` soit relu). Décoder le JSON à chaque fois
/// allouait un `JSONDecoder`, une `Data` et un objet par tap d'onglet. La
/// dernière valeur lue est donc conservée en mémoire : après le premier accès,
/// `load` ne fait plus qu'une lecture de dictionnaire.
enum FileFiltersStore {
    private static let lock = NSLock()
    /// Dernière valeur connue par onglet, telle que lue ou écrite par cette app.
    /// `nil` (clé absente) n'est jamais mémorisé : une première lecture doit
    /// pouvoir retomber sur les valeurs par défaut sans être confondue avec
    /// une entrée mise en cache.
    nonisolated(unsafe) private static var cached: [FileBrowserScope: FileFilters] = [:]

    private static func key(for scope: FileBrowserScope) -> String {
        "\(scope.rawValue)FileFilters"
    }

    static func load(
        scope: FileBrowserScope,
        defaults: UserDefaults = .standard
    ) -> FileFilters {
        lock.lock()
        if let memoized = cached[scope] {
            lock.unlock()
            return memoized
        }
        lock.unlock()

        guard let data = defaults.data(forKey: key(for: scope)),
              let filters = try? JSONDecoder().decode(FileFilters.self, from: data)
        else { return FileFilters() }

        lock.lock()
        cached[scope] = filters
        lock.unlock()
        return filters
    }

    static func save(
        _ filters: FileFilters,
        scope: FileBrowserScope,
        defaults: UserDefaults = .standard
    ) {
        lock.lock()
        cached[scope] = filters
        lock.unlock()
        guard let data = try? JSONEncoder().encode(filters) else { return }
        defaults.set(data, forKey: key(for: scope))
    }

    /// Oublie les valeurs mémorisées. Réservé aux tests et à une remise à zéro
    /// de session : l'app se fie sinon à ce que `save` vient d'écrire.
    static func clearCache() {
        lock.lock()
        cached.removeAll()
        lock.unlock()
    }
}
