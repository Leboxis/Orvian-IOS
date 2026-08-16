import Foundation

/// Source de fichiers pour les grilles paginées.
enum FileSource: Hashable {
    case directory(Int)
    case recents
    case favorites
    case media
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
        case .recents:
            endpoint = .recents(driveId: driveId, cursor: cursor)
        case .favorites:
            endpoint = .favorites(driveId: driveId, cursor: cursor)
        case .media:
            endpoint = .media(driveId: driveId, cursor: cursor)
        }
        return try await api.get(CursorPage<DriveFile>.self, endpoint)
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

    func thumbnailData(driveId: Int, fileId: Int, pixels: Int) async throws -> Data {
        try await api.data(.thumbnail(driveId: driveId, fileId: fileId, pixels: pixels))
    }
}
