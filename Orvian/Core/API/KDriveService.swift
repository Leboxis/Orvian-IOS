import Foundation

/// Source de fichiers pour les grilles paginées.
enum FileSource: Hashable {
    case directory(Int)
    case favorites(limit: Int = 60)
    case recents(limit: Int = 12)
    case category(Int)
    case trash
    case search(query: String, directoryId: Int?)

    /// Raccourci requis par les comparaisons et affectations `.favorites`
    /// (le cas associé porte un paramètre avec défaut et n'est pas référence
    /// ainsi sans lui).
    static var favorites: FileSource { .favorites() }
}

/// Couche Repository : unique point d'accès aux données kDrive.
///
/// Le type est volontairement réduit à son noyau (client HTTP partagé) ; les
/// opérations sont réparties par domaine dans les extensions
/// `KDriveService+Accounts`, `+Files`, `+Categories`, `+Media`, `+Upload` et
/// `+Mutations`.
struct KDriveService {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }
}
