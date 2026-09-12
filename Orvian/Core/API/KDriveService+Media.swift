import Foundation

/// Médias : favoris, URL temporaires et miniatures.
extension KDriveService {
    func setFavorite(driveId: Int, fileId: Int, favorite: Bool) async throws {
        try await api.sendEmpty(.favorite(driveId: driveId, fileId: fileId), method: favorite ? "POST" : "DELETE")
    }

    func temporaryURL(driveId: Int, fileId: Int) async throws -> URL {
        let wrapper = try await api.get(DataResponse<TemporaryURL>.self, .temporaryURL(driveId: driveId, fileId: fileId))
        guard let string = wrapper.data?.temporaryUrl, let url = URL(string: string) else {
            throw APIError.invalidResponse
        }
        return url
    }

    func thumbnailData(driveId: Int, fileId: Int, isTrashed: Bool = false) async throws -> Data {
        let endpoint: Endpoint = isTrashed
            ? .trashedThumbnail(driveId: driveId, fileId: fileId)
            : .thumbnail(driveId: driveId, fileId: fileId)
        // Les miniatures disposent de leur propre cache disque : inutile de
        // dupliquer leurs octets dans le cache HTTP partagé.
        return try await api.data(endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    }
}
