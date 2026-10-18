import CryptoKit
import Foundation

/// Un morceau prêt à l'envoi : son fichier temporaire (sans charger le morceau
/// entier en RAM), sa taille et son empreinte SHA-256 calculée pendant
/// l'écriture.
struct ChunkPayload: Sendable {
    let url: URL
    let size: Int
    let sha256: String
}

/// Lecture séquentielle hors du MainActor pour les uploads découpés.
private actor UploadChunkReader {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    /// Lit le morceau suivant en l'écrivant directement dans un fichier
    /// temporaire : la mémoire réservée est celle d'un bloc de copie (1 Mo),
    /// pas celle du morceau entier — et encore moins de sa copie interne
    /// `URLSession`. Renvoie `nil` à la fin du fichier.
    func next(maxLength: Int) throws -> ChunkPayload? {
        let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orvian-chunk-\(UUID().uuidString)")
        var keepPayload = false
        defer {
            if !keepPayload { try? FileManager.default.removeItem(at: chunkURL) }
        }
        try Task.checkCancellation()
        guard FileManager.default.createFile(atPath: chunkURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: chunkURL)
        defer { try? output.close() }

        var digest = SHA256()
        var written = 0
        let blockSize = 1 << 20
        while written < maxLength {
            try Task.checkCancellation()
            let block = try handle.read(upToCount: min(blockSize, maxLength - written)) ?? Data()
            if block.isEmpty { break }
            digest.update(data: block)
            try output.write(contentsOf: block)
            written += block.count
        }
        guard written > 0 else { return nil }
        // Fermer avec propagation d'erreur avant de transférer la propriété
        // du fichier à l'appelant. Le defer nettoie tout échec intermédiaire.
        try output.close()
        try Task.checkCancellation()
        keepPayload = true
        return ChunkPayload(
            url: chunkURL,
            size: written,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}

/// Fenêtre glissante : au plus quatre fichiers de segments sur disque/en vol.
/// Le retour confirme tous les segments ; le push final peut alors commencer.
private enum UploadChunkPipeline {
    static let chunkSize = 32 * 1_024 * 1_024
    static let maxConcurrentChunks = 4

    static func send(
        reader: UploadChunkReader,
        totalChunks: Int,
        upload: @escaping @Sendable (Int, ChunkPayload) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            do {
                for number in 1...totalChunks {
                    if number > maxConcurrentChunks { try await group.next() }
                    try Task.checkCancellation()
                    guard let chunk = try await reader.next(maxLength: chunkSize) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    group.addTask {
                        // Le même fichier reste disponible durant les réessais.
                        defer { try? FileManager.default.removeItem(at: chunk.url) }
                        try Task.checkCancellation()
                        try await upload(number, chunk)
                    }
                }
                while let _ = try await group.next() {}
                try Task.checkCancellation()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

/// Les callbacks URLSession sont synchrones et peuvent venir de plusieurs
/// segments. Le verrou protège les octets cumulés, y compris lors d'un réessai.
private final class UploadChunkProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let totalSize: Int
    private var bytesByChunk: [Int: Double] = [:]
    private var sentBytes = 0.0

    init(totalSize: Int) { self.totalSize = totalSize }

    func update(number: Int, size: Int, fraction: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let previous = bytesByChunk[number] ?? 0
        let current = max(previous, Double(size) * min(max(fraction, 0), 1))
        bytesByChunk[number] = current
        sentBytes += current - previous
        return min(sentBytes / Double(max(totalSize, 1)), 1)
    }
}

/// Création de dossiers, upload simple et upload par sessions.
extension KDriveService {
    /// Infomaniak recommande une session à partir de 100 Mo. Une petite marge
    /// évite qu'un fichier proche de la limite soit refusé par un intermédiaire.
    private static let directUploadLimit = 95 * 1_024 * 1_024
    private static let directUploadMaximumAttempts = 3
    private static let uploadChunkSize = UploadChunkPipeline.chunkSize
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
    func createFolder(driveId: Int, directoryId: Int, name: String, credentialFingerprint: String? = TokenStore.credentialFingerprint()) async throws {
        let body = try JSONEncoder().encode(CreateFolderRequest(name: name))
        try await api.post(.createFolder(driveId: driveId, directoryId: directoryId), body: body,
                           contentType: "application/json", credentialFingerprint: credentialFingerprint)
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
        attemptStarted: @escaping @Sendable (Int) -> Void,
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

        var lastError: Error = APIError.invalidResponse
        for attempt in 1...Self.directUploadMaximumAttempts {
            try Task.checkCancellation()
            attemptStarted(attempt)
            do {
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
            } catch {
                lastError = error
                try Task.checkCancellation()
                guard attempt < Self.directUploadMaximumAttempts,
                      UploadSafety.mayRetryDirectUpload(error)
                else {
                    if UploadSafety.outcomeMayBeUnknown(error) { throw UploadOutcomeUnknown() }
                    throw error
                }
                let delaySeconds = Int64(1 << (attempt - 1))
                try await Task.sleep(for: .seconds(delaySeconds))
            }
        }
        throw lastError
    }

    /// Les fichiers d'au moins 95 Mo suivent le protocole de session recommandé
    /// par Infomaniak. Quatre segments de 32 Mio au plus partent en parallèle,
    /// puis la session est finalisée après confirmation de tous les segments.
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
        let credential = try await api.captureUploadCredential()
        let body = try JSONEncoder().encode(request)
        let response = try await api.postDecoded(
            DataResponse<UploadSession>.self,
            .startUploadSession(driveId: driveId),
            body: body,
            originatingCredential: credential.fingerprint
        )
        guard response.result == nil || response.result == "success" || response.result == "asynchronous",
              let session = response.data,
              session.result != false,
              let token = session.resolvedToken,
              let uploadURL = session.uploadURL,
              APIClient.isTrustedUploadURL(uploadURL)
        else { throw APIError.invalidResponse }

        var cleanup = try await api.uploadSessionCleanup(driveId: driveId, sessionToken: token, credential: credential)
        var finishRequested = false
        do {
            let reader = try UploadChunkReader(url: fileURL)
            let chunkProgress = UploadChunkProgress(totalSize: totalSize)
            try await UploadChunkPipeline.send(reader: reader, totalChunks: totalChunks) { number, chunk in
                let chunkURL = try Self.chunkURL(
                    from: uploadURL,
                    driveId: driveId,
                    token: token,
                    number: number,
                    size: chunk.size,
                    hash: chunk.sha256
                )

                try await self.uploadChunk(
                    to: chunkURL,
                    payload: chunk,
                    number: number,
                    originatingCredential: credential.fingerprint,
                    progress: { fraction in
                        // Réserver le dernier pourcent à la confirmation du push.
                        progress(0.99 * chunkProgress.update(number: number, size: chunk.size, fraction: fraction))
                    }
                )
                progress(0.99 * chunkProgress.update(number: number, size: chunk.size, fraction: 1))
            }

            try Task.checkCancellation()
            finishRequested = true
            let finished = try await api.postDecoded(
                DataResponse<FinishedUpload>.self,
                .finishUploadSession(driveId: driveId, token: token),
                body: try JSONEncoder().encode(FinishUploadSessionRequest(lastModifiedAt: lastModifiedAt)),
                originatingCredential: credential.fingerprint
            )
            guard finished.result == nil || finished.result == "success" || finished.result == "asynchronous",
                  let file = finished.data?.file
            else { throw APIError.invalidResponse }
            cleanup.confirmed()
            progress(1)
            return file
        } catch {
            // Après l'envoi du finish, une réponse perdue (y compris annulée)
            // ne prouve pas l'absence de fichier : ne jamais le supprimer à l'aveugle.
            if finishRequested && (UploadSafety.isCancellation(error) || UploadSafety.outcomeMayBeUnknown(error)) {
                throw UploadOutcomeUnknown()
            }
            // La requête DELETE garde l'identité d'origine et survit à l'annulation
            // de cette tâche, même lorsque la déconnexion a déjà effacé le token.
            await cleanup.cancel()
            throw error
        }
    }

    /// Un statut HTTP 2xx ne confirme pas à lui seul qu'un morceau a été
    /// enregistré : l'API peut répondre `error` ou `uploading` dans son JSON.
    /// Réessayer le même numéro évite une clôture de session prématurée, qui
    /// faisait échouer les fichiers dépassant la limite d'upload direct.
    private func uploadChunk(
        to url: URL,
        payload: ChunkPayload,
        number: Int,
        originatingCredential: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var lastError: Error = APIError.invalidResponse

        for attempt in 1...Self.uploadChunkMaximumAttempts {
            try Task.checkCancellation()
            do {
                // `upload_url` est l'hôte désigné par Infomaniak pour les
                // morceaux ; il ne faut pas les envoyer à api.infomaniak.com.
                let responseData = try await api.uploadFile(
                    to: url,
                    fileURL: payload.url,
                    contentType: "application/octet-stream",
                    originatingCredential: originatingCredential,
                    progress: progress
                )
                let response = try JSONDecoder.api.decode(DataResponse<UploadChunk>.self, from: responseData)
                guard response.result == nil || response.result == "success" || response.result == "asynchronous",
                      let chunk = response.data,
                      chunk.status == "ok",
                      chunk.number == nil || chunk.number == number,
                      chunk.size == nil || chunk.size == payload.size
                else { throw APIError.invalidResponse }
                return
            } catch {
                lastError = error
                // Une annulation explicite n'est pas un échec réseau : on la
                // propage immédiatement sans la transformer en doute sur le
                // résultat côté serveur.
                if UploadSafety.isCancellation(error) { throw error }
                try Task.checkCancellation()
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
