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
    private var refreshGenerationByDrive: [Int: Int] = [:]

    private init() {}

    /// Index id → catégorie du drive, vide tant que le chargement n'a pas eu lieu.
    func categories(for driveId: Int) -> [Int: Category] {
        categoriesByDrive[driveId] ?? [:]
    }

    /// Indique si les catégories du drive ont déjà été chargées cette session
    /// (y compris pour un drive sans tag : liste vide ≠ jamais chargé).
    func hasLoaded(for driveId: Int) -> Bool {
        categoriesByDrive[driveId] != nil
    }

    /// Liste des catégories du drive déjà chargées (vide si aucune donnée).
    func categoryList(for driveId: Int) -> [Category] {
        categoriesByDrive[driveId].map { Array($0.values) } ?? []
    }

    /// Charge les catégories d'un drive (une seule fois par session).
    func ensureLoaded(for driveId: Int) async {
        guard categoriesByDrive[driveId] == nil else { return }
        _ = try? await refresh(for: driveId)
    }

    /// Revalide le cache apres une creation, un renommage ou une suppression.
    @discardableResult
    func refresh(for driveId: Int) async throws -> [Category] {
        let generation = (refreshGenerationByDrive[driveId] ?? 0) + 1
        refreshGenerationByDrive[driveId] = generation
        let categories = try await KDriveService().categories(driveId: driveId)
        guard refreshGenerationByDrive[driveId] == generation else {
            return categoriesByDrive[driveId].map { Array($0.values) } ?? categories
        }
        categoriesByDrive[driveId] = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return categories
    }

    func upsert(_ category: Category, for driveId: Int) {
        guard var categories = categoriesByDrive[driveId] else { return }
        categories[category.id] = category
        categoriesByDrive[driveId] = categories
    }

    func remove(categoryId: Int, for driveId: Int) {
        guard var categories = categoriesByDrive[driveId] else { return }
        categories.removeValue(forKey: categoryId)
        categoriesByDrive[driveId] = categories
    }
}
