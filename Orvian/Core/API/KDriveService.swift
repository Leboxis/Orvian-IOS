import Foundation

/// Lecture séquentielle hors du MainActor pour les uploads découpés.
private actor UploadChunkReader {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func next(maxLength: Int) throws -> Data {
        try handle.read(upToCount: maxLength) ?? Data()
    }
}

/// Source de fichiers pour les grilles paginées.
enum FileSource: Hashable {
    case directory(Int)
    case favorites(limit: Int = 60)
    case recents(limit: Int = 12)
    case mostViewed(limit: Int = 12)
    case category(Int)
    case trash
    case search(query: String, directoryId: Int?)

    static var favorites: FileSource { .favorites() }
    static var recents: FileSource { .recents() }
    static var mostViewed: FileSource { .mostViewed() }
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
        case let .favorites(limit):
            endpoint = .favorites(driveId: driveId, cursor: cursor, limit: limit)
        case let .recents(limit):
            // 1) Priorité /files/last_modified (fichiers modifiés/uploadés récemment sur le drive)
            do {
                let res = try await api.get(CursorPage<DriveFile>.self, .lastModified(driveId: driveId, cursor: cursor, limit: limit))
                if let data = res.data, !data.isEmpty {
                    return res
                }
            } catch { }

            // 2) Fallback /files/recents
            do {
                let res = try await api.get(CursorPage<DriveFile>.self, .recents(driveId: driveId, cursor: cursor, limit: limit))
                if let data = res.data, !data.isEmpty {
                    return res
                }
            } catch { }

            // 3) Fallback /files/activities
            do {
                let res = try await api.get(CursorPage<DriveFile>.self, .activities(driveId: driveId, cursor: cursor, limit: limit))
                if let data = res.data, !data.isEmpty {
                    return res
                }
            } catch { }

            // 4) Dernier recours : recherche globale
            endpoint = .search(driveId: driveId, query: "", directoryId: nil, cursor: cursor, limit: limit)
        case let .mostViewed(limit):
            let files = MediaUsageStore.mostViewedFiles(driveId: driveId, limit: limit)
            return CursorPage<DriveFile>(data: files, cursor: nil, hasMore: false)
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

    /// Infomaniak recommande une session à partir de 100 Mo. Une petite marge
    /// évite qu'un fichier proche de la limite soit refusé par un intermédiaire.
    private static let directUploadLimit = 95 * 1_024 * 1_024
    private static let uploadChunkSize = 20 * 1_024 * 1_024
    private static let uploadChunkMaximumAttempts = 3

    private struct StartUploadSessionRequest: Encodable {
        let totalSize: Int
        let fileName: String
        let totalChunks: Int
        let conflict: String
        let directoryId: Int
        let lastModifiedAt: Int

        enum CodingKeys: String, CodingKey {
            case conflict
            case totalSize = "total_size"
            case fileName = "file_name"
            case totalChunks = "total_chunks"
            case directoryId = "directory_id"
            case lastModifiedAt = "last_modified_at"
        }
    }

    private struct UploadSession: Decodable {
        let token: String?
        let sessionToken: String?
        let uploadURL: URL?
        let result: Bool?

        enum CodingKeys: String, CodingKey {
            case token
            case sessionToken = "session_token"
            case uploadURL = "upload_url"
        }

        var resolvedToken: String? { token ?? sessionToken }
    }

    private struct UploadChunk: Decodable {
        let number: Int?
        let size: Int?
        let status: String?
    }

    private struct FinishedUpload: Decodable {
        let file: DriveFile
    }

    private struct FinishUploadSessionRequest: Encodable {
        let lastModifiedAt: Int

        enum CodingKeys: String, CodingKey {
            case lastModifiedAt = "last_modified_at"
        }
    }

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
            .upload(
                driveId: driveId,
                directoryId: directoryId,
                fileName: fileName,
                totalSize: data.count,
                lastModifiedAt: Int(Date().timeIntervalSince1970)
            ),
            body: data,
            contentType: mimeType.isEmpty ? "application/octet-stream" : mimeType
        )
    }

    /// Upload d'un fichier local par streaming (sans buffer Data en mémoire) dans `directoryId`.
    func uploadFile(
        driveId: Int,
        directoryId: Int,
        fileURL: URL,
        fileName: String,
        totalSize: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DriveFile {
        let lastModifiedAt = Self.modificationTimestamp(for: fileURL)
        if totalSize >= Self.directUploadLimit {
            return try await uploadFileInChunks(
                driveId: driveId,
                directoryId: directoryId,
                fileURL: fileURL,
                fileName: fileName,
                totalSize: totalSize,
                lastModifiedAt: lastModifiedAt,
                progress: progress
            )
        }

        return try await api.uploadFile(
            .upload(
                driveId: driveId,
                directoryId: directoryId,
                fileName: fileName,
                totalSize: totalSize,
                lastModifiedAt: lastModifiedAt
            ),
            fileURL: fileURL,
            // L'endpoint reçoit le fichier comme corps binaire brut. Le type
            // réel reste transmis à kDrive via le nom et son extension.
            contentType: "application/octet-stream",
            progress: progress
        )
    }

    /// Les fichiers d'au moins 95 Mo suivent le protocole de session recommandé
    /// par Infomaniak. Chaque morceau est confirmé avant le suivant.
    private func uploadFileInChunks(
        driveId: Int,
        directoryId: Int,
        fileURL: URL,
        fileName: String,
        totalSize: Int,
        lastModifiedAt: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DriveFile {
        let totalChunks = max(1, Int(ceil(Double(totalSize) / Double(Self.uploadChunkSize))))
        let request = StartUploadSessionRequest(
            totalSize: totalSize,
            fileName: fileName,
            totalChunks: totalChunks,
            conflict: "rename",
            directoryId: directoryId,
            lastModifiedAt: lastModifiedAt
        )
        let body = try JSONEncoder().encode(request)
        let response = try await api.postDecoded(
            DataResponse<UploadSession>.self,
            .startUploadSession(driveId: driveId),
            body: body
        )
        guard response.result == nil || response.result == "success" || response.result == "asynchronous",
              let session = response.data,
              session.result != false,
              let token = session.resolvedToken,
              let uploadURL = session.uploadURL,
              APIClient.isTrustedUploadURL(uploadURL)
        else { throw APIError.invalidResponse }

        do {
            let reader = try UploadChunkReader(url: fileURL)
            for number in 1...totalChunks {
                try Task.checkCancellation()
                let chunk = try await reader.next(maxLength: Self.uploadChunkSize)
                guard !chunk.isEmpty else { throw APIError.invalidResponse }
                let chunkURL = try Self.chunkURL(
                    from: uploadURL,
                    number: number,
                    size: chunk.count
                )

                try await uploadChunk(
                    to: chunkURL,
                    data: chunk,
                    number: number,
                    totalChunks: totalChunks,
                    progress: progress
                )
            }

            let finished = try await api.postDecoded(
                DataResponse<FinishedUpload>.self,
                .finishUploadSession(driveId: driveId, token: token),
                body: try JSONEncoder().encode(FinishUploadSessionRequest(lastModifiedAt: lastModifiedAt))
            )
            guard finished.result == nil || finished.result == "success" || finished.result == "asynchronous",
                  let file = finished.data?.file
            else { throw APIError.invalidResponse }
            progress(1)
            return file
        } catch {
            try? await api.sendEmpty(
                .cancelUploadSession(driveId: driveId, token: token),
                method: "DELETE"
            )
            throw error
        }
    }

    /// Un statut HTTP 2xx ne confirme pas à lui seul qu'un morceau a été
    /// enregistré : l'API peut répondre `error` ou `uploading` dans son JSON.
    /// Réessayer le même numéro évite une clôture de session prématurée, qui
    /// faisait échouer les fichiers dépassant la limite d'upload direct.
    private func uploadChunk(
        to url: URL,
        data: Data,
        number: Int,
        totalChunks: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var lastError: Error = APIError.invalidResponse

        for attempt in 1...Self.uploadChunkMaximumAttempts {
            try Task.checkCancellation()
            do {
                // `upload_url` est l'hôte désigné par Infomaniak pour les
                // morceaux ; il ne faut pas les envoyer à api.infomaniak.com.
                let responseData = try await api.uploadData(
                    to: url,
                    data: data,
                    contentType: "application/octet-stream",
                    progress: { chunkProgress in
                        let completedChunks = Double(number - 1)
                        progress((completedChunks + chunkProgress) / Double(totalChunks))
                    }
                )
                let response = try JSONDecoder.api.decode(DataResponse<UploadChunk>.self, from: responseData)
                guard response.result == nil || response.result == "success" || response.result == "asynchronous",
                      let chunk = response.data,
                      chunk.status == "ok",
                      chunk.number == nil || chunk.number == number,
                      chunk.size == nil || chunk.size == data.count
                else { throw APIError.invalidResponse }
                return
            } catch {
                lastError = error
                guard attempt < Self.uploadChunkMaximumAttempts else { break }
                try await Task.sleep(for: .seconds(Int64(attempt)))
            }
        }

        throw lastError
    }

    private static func modificationTimestamp(for fileURL: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let date = attributes?[.modificationDate] as? Date
        return Int((date ?? Date()).timeIntervalSince1970)
    }

    /// `upload_url` peut contenir des paramètres nécessaires à l'hôte de
    /// transfert. Ils sont préservés et seuls les paramètres du morceau sont
    /// ajoutés.
    private static func chunkURL(from uploadURL: URL, number: Int, size: Int) throws -> URL {
        guard APIClient.isTrustedUploadURL(uploadURL),
              var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)
        else { throw APIError.invalidURL }
        let preservedQuery = (components.queryItems ?? []).filter {
            $0.name != "chunk_number" && $0.name != "chunk_size"
        }
        components.queryItems = preservedQuery + [
            URLQueryItem(name: "chunk_number", value: String(number)),
            URLQueryItem(name: "chunk_size", value: String(size)),
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        return url
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

    /// Déplace un fichier ou dossier vers `destinationDirectoryId`.
    func move(driveId: Int, fileId: Int, destinationDirectoryId: Int) async throws {
        try await api.sendEmpty(
            .move(driveId: driveId, fileId: fileId, destinationDirectoryId: destinationDirectoryId),
            method: "POST"
        )
    }
}
