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
enum FileFiltersStore {
    private static func key(for scope: FileBrowserScope) -> String {
        "\(scope.rawValue)FileFilters"
    }

    static func load(
        scope: FileBrowserScope,
        defaults: UserDefaults = .standard
    ) -> FileFilters {
        guard let data = defaults.data(forKey: key(for: scope)),
              let filters = try? JSONDecoder().decode(FileFilters.self, from: data)
        else { return FileFilters() }
        return filters
    }

    static func save(
        _ filters: FileFilters,
        scope: FileBrowserScope,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(filters) else { return }
        defaults.set(data, forKey: key(for: scope))
    }
}
