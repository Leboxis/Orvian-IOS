import Foundation

/// Source de fichiers pour les grilles paginées.
enum FileSource: Hashable {
    case directory(Int)
    case favorites
    case category(Int)
    case trash
    case search(query: String, directoryId: Int?)
}

/// Couche Repository : unique point d'accès aux données kDrive.
struct KDriveService {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    // MARK: - Comptes & drives

    func accounts() async throws -> [InfomaniakAccount] {
        try await api.get(DataResponse<[InfomaniakAccount]>.self, .accounts).data ?? []
    }

    func drives(accountId: Int) async throws -> [Drive] {
        try await api.get(DataResponse<[Drive]>.self, .drives(accountId: accountId)).data ?? []
    }

    /// Parcourt les comptes du token et renvoie le premier qui possède des
    /// drives (la plupart des tokens personnels n'ont qu'un compte actif).
    func discoverDrives() async throws -> (accountId: Int, drives: [Drive]) {
        let accounts = try await self.accounts()
        var lastError: Error = APIError.invalidResponse
        for account in accounts {
            do {
                let drives = try await self.drives(accountId: account.id)
                if !drives.isEmpty {
                    return (account.id, drives)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Listes paginées

    func page(_ source: FileSource, driveId: Int, cursor: String?) async throws -> CursorPage<DriveFile> {
        let endpoint: Endpoint
        switch source {
        case let .directory(directoryId):
            endpoint = .directoryContent(driveId: driveId, directoryId: directoryId, cursor: cursor)
        case .favorites:
            endpoint = .favorites(driveId: driveId, cursor: cursor)
        case let .category(categoryId):
            endpoint = .categoryFiles(driveId: driveId, categoryId: categoryId, cursor: cursor)
        case .trash:
            endpoint = .trashContent(driveId: driveId, cursor: cursor)
        case let .search(query, directoryId):
            endpoint = .search(driveId: driveId, query: query, directoryId: directoryId, cursor: cursor)
        }
        return try await api.get(CursorPage<DriveFile>.self, endpoint)
    }

    // MARK: - Catégories

    func categories(driveId: Int) async throws -> [Category] {
        try await api.get(DataResponse<[Category]>.self, .categories(driveId: driveId)).data ?? []
    }

    private struct CreateCategoryRequest: Encodable {
        let name: String
        let color: String
    }

    /// Crée une catégorie (tag) avec sa couleur `#rrggbb`.
    func createCategory(driveId: Int, name: String, color: String) async throws {
        let body = try JSONEncoder().encode(CreateCategoryRequest(name: name, color: color))
        try await api.post(.categories(driveId: driveId), body: body, contentType: "application/json")
    }

    /// Applique une catégorie (tag) sur un fichier.
    func addCategory(driveId: Int, fileId: Int, categoryId: Int) async throws {
        try await api.sendEmpty(.fileCategory(driveId: driveId, fileId: fileId, categoryId: categoryId), method: "POST")
    }

    /// Retire une catégorie (tag) d'un fichier.
    func removeCategory(driveId: Int, fileId: Int, categoryId: Int) async throws {
        try await api.sendEmpty(.fileCategory(driveId: driveId, fileId: fileId, categoryId: categoryId), method: "DELETE")
    }

    // MARK: - Favoris

    func setFavorite(driveId: Int, fileId: Int, favorite: Bool) async throws {
        try await api.sendEmpty(.favorite(driveId: driveId, fileId: fileId), method: favorite ? "POST" : "DELETE")
    }

    // MARK: - Média

    func temporaryURL(driveId: Int, fileId: Int) async throws -> URL {
        let wrapper = try await api.get(DataResponse<TemporaryURL>.self, .temporaryURL(driveId: driveId, fileId: fileId))
        guard let string = wrapper.data?.temporaryUrl, let url = URL(string: string) else {
            throw APIError.invalidResponse
        }
        return url
    }

    func thumbnailData(driveId: Int, fileId: Int, pixels: Int, isTrashed: Bool = false) async throws -> Data {
        let endpoint: Endpoint = isTrashed
            ? .trashedThumbnail(driveId: driveId, fileId: fileId, pixels: pixels)
            : .thumbnail(driveId: driveId, fileId: fileId, pixels: pixels)
        return try await api.data(endpoint)
    }

    // MARK: - Création & upload

    private struct CreateFolderRequest: Encodable {
        let name: String
    }

    /// Crée un dossier dans `directoryId`.
    func createFolder(driveId: Int, directoryId: Int, name: String) async throws {
        let body = try JSONEncoder().encode(CreateFolderRequest(name: name))
        try await api.post(.createFolder(driveId: driveId, directoryId: directoryId), body: body, contentType: "application/json")
    }

    /// Upload d'un fichier complet (corps brut) dans `directoryId`.
    func upload(driveId: Int, directoryId: Int, data: Data, fileName: String, mimeType: String) async throws {
        try await api.post(
            .upload(driveId: driveId, directoryId: directoryId, fileName: fileName, totalSize: data.count),
            body: data,
            contentType: mimeType.isEmpty ? "application/octet-stream" : mimeType
        )
    }

    // MARK: - Suppression & renommage

    /// Déplace un fichier ou dossier dans la corbeille.
    func trash(driveId: Int, fileId: Int) async throws {
        try await api.sendEmpty(.trash(driveId: driveId, fileId: fileId), method: "DELETE")
    }

    /// Supprime définitivement un fichier ou dossier de la corbeille.
    func permanentlyDelete(driveId: Int, fileId: Int) async throws {
        try await api.sendEmpty(.permanentDelete(driveId: driveId, fileId: fileId), method: "DELETE")
    }

    /// Restaure un fichier ou dossier depuis la corbeille.
    /// `destinationDirectoryId` : dossier de destination (dossier d'origine
    /// ou racine du drive).
    func restore(driveId: Int, fileId: Int, destinationDirectoryId: Int) async throws {
        let body = try JSONEncoder().encode(["destination_directory_id": destinationDirectoryId])
        try await api.post(.restore(driveId: driveId, fileId: fileId), body: body, contentType: "application/json")
    }

    /// Renomme un fichier ou dossier.
    func rename(driveId: Int, fileId: Int, name: String) async throws {
        let body = try JSONEncoder().encode(["name": name])
        try await api.post(.rename(driveId: driveId, fileId: fileId), body: body, contentType: "application/json")
    }
}
