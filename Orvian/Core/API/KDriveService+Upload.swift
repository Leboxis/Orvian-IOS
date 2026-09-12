import CryptoKit
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

    func next(maxLength: Int) throws -> (data: Data, sha256: String) {
        let data = try handle.read(upToCount: maxLength) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, digest)
    }
}

/// Création de dossiers, upload simple et upload par sessions.
extension KDriveService {
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
            case result
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

    /// Remplace le contenu d'un fichier existant (nouvelle version) : utilisé
    /// par la visionneuse de texte pour enregistrer les modifications.
    func uploadContent(driveId: Int, fileId: Int, data: Data) async throws {
        try await api.post(
            .uploadContent(
                driveId: driveId,
                fileId: fileId,
                totalSize: data.count,
                lastModifiedAt: Int(Date().timeIntervalSince1970)
            ),
            body: data,
            contentType: "text/plain; charset=utf-8"
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
                guard !chunk.data.isEmpty else { throw APIError.invalidResponse }
                let chunkURL = try Self.chunkURL(
                    from: uploadURL,
                    driveId: driveId,
                    token: token,
                    number: number,
                    size: chunk.data.count,
                    hash: chunk.sha256
                )

                try await uploadChunk(
                    to: chunkURL,
                    data: chunk.data,
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

    /// `upload_url` renvoyé par `/upload/session/start` est l'**hôte** dédié au
    /// transfert des morceaux (ex. `upload.kdrive.infomaniak.com`), pas l'URL
    /// complète du chunk. Comme l'app kDrive officielle, on repart du chemin
    /// canonique `/3/drive/{drive_id}/upload/session/{token}/chunk` et on ne
    /// remplace que l'hôte, en préservant les éventuels paramètres renvoyés
    /// par l'API.
    private static func chunkURL(
        from uploadURL: URL,
        driveId: Int,
        token: String,
        number: Int,
        size: Int,
        hash: String
    ) throws -> URL {
        guard APIClient.isTrustedUploadURL(uploadURL),
              let host = uploadURL.host?.lowercased(),
              let sourceComponents = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)
        else { throw APIError.invalidURL }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = uploadURL.port
        components.path = "/3/drive/\(driveId)/upload/session/\(token)/chunk"
        let preservedQuery = (sourceComponents.queryItems ?? []).filter {
            $0.name != "chunk_number" && $0.name != "chunk_size" && $0.name != "chunk_hash"
        }
        components.queryItems = preservedQuery + [
            URLQueryItem(name: "chunk_number", value: String(number)),
            URLQueryItem(name: "chunk_size", value: String(size)),
            URLQueryItem(name: "chunk_hash", value: "sha256:\(hash)"),
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }
}
