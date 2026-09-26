import Foundation

/// Capacités d'ordering de chaque `FileSource`.
///
/// Fichier dédié (et non une extension dans `KDriveService`) pour que la
/// règle tienne dans un seul module sans dépendre du client HTTP : elle sert
/// à la fois au garde-fou réseau et au tri local, et les deux doivent
/// répondre « le serveur trie » à la même question.
extension FileSource {
    /// Champs `order_by[]` acceptés par les endpoints qui parcourent le drive
    /// (dossier, favoris, corbeille).
    static let browsableOrderingFields: Set<String> = [
        "added_at", "last_modified_at", "mime_type", "name",
        "revised_at", "size", "type", "updated_at",
    ]

    /// Ordres que l'endpoint de cette source **honore réellement**, alias
    /// compris (`updated_at` → `last_modified_at` sur les endpoints de
    /// recherche). C'est l'intersection des `allowed:`/`aliases:` de
    /// `KDriveService.page(_:...)` : `FileFilters.sorted` s'en sert pour
    /// décider si un tri local est nécessaire, et `safeOrdering` reste le
    /// garde-fou qui empêche un HTTP 400.
    ///
    /// Les sources dont l'endpoint n'accepte que la date de modification
    /// (recherche, tags, cascade `recents`) doivent conserver un tri local :
    /// sans lui, `Taille`, `Type` et `Date d'importation` n'auraient aucun
    /// effet sur ces écrans.
    var supportedServerOrdering: Set<String> {
        switch self {
        case .directory, .favorites, .trash:
            return Self.browsableOrderingFields
        case .recents, .category, .search:
            // Cascade `recents` (last_modified → recents → activities →
            // search) : seule la date de modification est traduite par les
            // alias de chaque étage. `category` et `search` n'acceptent que
            // `last_modified_at`, avec alias `updated_at`.
            return ["updated_at", "last_modified_at"]
        }
    }

    /// Vrai quand le serveur a déjà filtré les résultats : relancer les
    /// mots-clés en local les masquerait (`localizedStandardContains` est
    /// plus strict que les règles de pertinence de l'API).
    var isServerFiltered: Bool {
        if case .search = self { return true }
        return false
    }
}
