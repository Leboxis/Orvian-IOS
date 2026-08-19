import Foundation
import Observation

/// Résout les identifiants `FileCategory.categoryId` vers les catégories
/// complètes (nom, couleur). L'API ne renvoie que des IDs dans les fichiers ;
/// la liste des catégories du drive est chargée une fois par session puis
/// mise en cache.
@MainActor
@Observable
final class CategoryLibrary {
    static let shared = CategoryLibrary()

    private var categoriesByDrive: [Int: [Int: Category]] = [:]

    private init() {}

    /// Index id → catégorie du drive, vide tant que le chargement n'a pas eu lieu.
    func categories(for driveId: Int) -> [Int: Category] {
        categoriesByDrive[driveId] ?? [:]
    }

    /// Charge les catégories d'un drive (une seule fois par session).
    func ensureLoaded(for driveId: Int) async {
        guard categoriesByDrive[driveId] == nil else { return }
        if let cats = try? await KDriveService().categories(driveId: driveId) {
            categoriesByDrive[driveId] = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0) })
        }
    }
}