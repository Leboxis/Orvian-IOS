import Foundation

/// Catégories (tags) : lecture, création, modification, application.
extension KDriveService {
    func categories(driveId: Int) async throws -> [Category] {
        try await api.get(DataResponse<[Category]>.self, .categories(driveId: driveId)).data ?? []
    }

    private struct CreateCategoryRequest: Encodable {
        let name: String
        let color: String
    }

    private struct UpdateCategoryRequest: Encodable {
        let name: String
        let color: String?
    }

    /// Crée une catégorie (tag) avec sa couleur `#rrggbb`.
    func createCategory(driveId: Int, name: String, color: String) async throws {
        let body = try JSONEncoder().encode(CreateCategoryRequest(name: name, color: color))
        try await api.post(.categories(driveId: driveId), body: body, contentType: "application/json")
    }

    /// Renomme ou modifie la couleur d'une catégorie (tag).
    func updateCategory(driveId: Int, categoryId: Int, name: String, color: String?) async throws {
        let body = try JSONEncoder().encode(UpdateCategoryRequest(name: name, color: color))
        try await api.put(.category(driveId: driveId, categoryId: categoryId), body: body)
    }

    /// Supprime une catégorie (tag) du drive.
    func deleteCategory(driveId: Int, categoryId: Int) async throws {
        try await api.sendEmpty(.category(driveId: driveId, categoryId: categoryId), method: "DELETE")
    }

    /// Applique une catégorie (tag) sur un fichier.
    func addCategory(driveId: Int, fileId: Int, categoryId: Int) async throws {
        try await api.sendEmpty(.fileCategory(driveId: driveId, fileId: fileId, categoryId: categoryId), method: "POST")
    }

    /// Retire une catégorie (tag) d'un fichier.
    func removeCategory(driveId: Int, fileId: Int, categoryId: Int) async throws {
        try await api.sendEmpty(.fileCategory(driveId: driveId, fileId: fileId, categoryId: categoryId), method: "DELETE")
    }

    private struct BulkCategoryRequest: Encodable {
        let fileIds: [Int]

        enum CodingKeys: String, CodingKey {
            case fileIds = "file_ids"
        }
    }

    /// Applique une catégorie (tag) sur plusieurs fichiers en un seul appel
    /// (`POST /2/drive/{id}/files/categories/{id}`, corps `{"file_ids": […]}`).
    func addCategory(driveId: Int, fileIds: [Int], categoryId: Int) async throws {
        let body = try JSONEncoder().encode(BulkCategoryRequest(fileIds: fileIds))
        try await api.post(.bulkFileCategory(driveId: driveId, categoryId: categoryId), body: body, contentType: "application/json")
    }

    /// Retire une catégorie (tag) de plusieurs fichiers en un seul appel
    /// (`DELETE /2/drive/{id}/files/categories/{id}`, même corps JSON).
    func removeCategory(driveId: Int, fileIds: [Int], categoryId: Int) async throws {
        let body = try JSONEncoder().encode(BulkCategoryRequest(fileIds: fileIds))
        try await api.send(.bulkFileCategory(driveId: driveId, categoryId: categoryId), method: "DELETE", body: body, contentType: "application/json")
    }
}
