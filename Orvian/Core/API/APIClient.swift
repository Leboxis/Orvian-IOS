import Foundation

/// Client HTTP pour l'API Infomaniak (`https://api.infomaniak.com`).
///
/// Actor : toutes les requêtes décodent hors du MainActor, la vue ne touche
/// jamais le réseau directement.
actor APIClient {
    static let shared = APIClient()

    static let baseURL = URL(string: "https://api.infomaniak.com")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Requêtes

    /// Requête authentifiée renvoyant les données brutes (miniatures…).
    func data(_ endpoint: Endpoint, method: String = "GET") async throws -> Data {
        let (data, response) = try await send(endpoint, method: method)
        try Self.check(response: response, data: data)
        return data
    }

    /// Requête authentifiée décodée en JSON.
    func get<T: Decodable>(_ type: T.Type = T.self, _ endpoint: Endpoint) async throws -> T {
        let data = try await self.data(endpoint)
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Requête « vide » (POST/DELETE renvoyant `{result, data}`).
    func sendEmpty(_ endpoint: Endpoint, method: String) async throws {
        let (data, response) = try await send(endpoint, method: method)
        try Self.check(response: response, data: data)
    }

    /// POST avec corps brut (JSON, octet-stream…). Lève une erreur si le
    /// statut HTTP n'est pas 2xx ; le contenu de la réponse est ignoré.
    func post(_ endpoint: Endpoint, body: Data, contentType: String) async throws {
        let (data, response) = try await send(endpoint, method: "POST", httpBody: body, contentType: contentType)
        try Self.check(response: response, data: data)
    }

    /// POST décodé, notamment pour l'ouverture et la fermeture des sessions
    /// d'upload où le corps de réponse fait partie de la confirmation.
    func postDecoded<T: Decodable>(
        _ type: T.Type = T.self,
        _ endpoint: Endpoint,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> T {
        let (data, response) = try await send(
            endpoint,
            method: "POST",
            httpBody: body,
            contentType: body == nil ? nil : contentType
        )
        try Self.check(response: response, data: data)
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// PUT avec corps brut (JSON…). Lève une erreur si le statut HTTP n'est pas 2xx.
    func put(_ endpoint: Endpoint, body: Data, contentType: String = "application/json") async throws {
        let (data, response) = try await send(endpoint, method: "PUT", httpBody: body, contentType: contentType)
        try Self.check(response: response, data: data)
    }

    /// Upload d'un fichier local par streaming (évite le chargement du fichier en RAM).
    /// La réponse doit contenir le fichier créé : un simple statut HTTP 2xx ne
    /// suffit pas à confirmer que kDrive l'a effectivement enregistré.
    func uploadFile(
        _ endpoint: Endpoint,
        fileURL: URL,
        contentType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DriveFile {
        var request = try request(for: endpoint, method: "POST")
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        do {
            let delegate = UploadProgressDelegate(progress: progress)
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let uploadSession = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: delegateQueue
            )
            defer { uploadSession.finishTasksAndInvalidate() }

            let (data, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.continuation = continuation
                    uploadSession.uploadTask(with: request, fromFile: fileURL).resume()
                }
            } onCancel: {
                uploadSession.invalidateAndCancel()
            }
            try Self.check(response: response, data: data)
            do {
                let envelope = try JSONDecoder.api.decode(DataResponse<DriveFile>.self, from: data)
                guard envelope.result == nil
                        || envelope.result == "success"
                        || envelope.result == "asynchronous"
                else {
                    throw APIError.invalidResponse
                }
                guard let uploadedFile = envelope.data else {
                    throw APIError.invalidResponse
                }
                return uploadedFile
            } catch let error as APIError {
                throw error
            } catch {
                throw APIError.decoding(error)
            }
        } catch {
            if error is APIError {
                throw error
            }
            throw APIError.network(error)
        }
    }

    /// Envoie un morceau binaire d'une session avec une progression réelle.
    func uploadData(
        _ endpoint: Endpoint,
        data: Data,
        contentType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = try request(for: endpoint, method: "POST")
        try await uploadData(request: &request, data: data, contentType: contentType, progress: progress)
    }

    /// Envoie un morceau vers l'URL dédiée renvoyée par `upload/session/start`.
    /// Cette URL reste contrôlée : seuls les hôtes Infomaniak autorisés peuvent
    /// recevoir l'en-tête Bearer de l'utilisateur.
    func uploadData(
        to url: URL,
        data: Data,
        contentType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = try uploadRequest(for: url, method: "POST")
        try await uploadData(request: &request, data: data, contentType: contentType, progress: progress)
    }

    private func uploadData(
        request: inout URLRequest,
        data: Data,
        contentType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        do {
            let delegate = UploadProgressDelegate(progress: progress)
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let uploadSession = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: delegateQueue
            )
            defer { uploadSession.finishTasksAndInvalidate() }

            let (responseData, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.continuation = continuation
                    uploadSession.uploadTask(with: request, from: data).resume()
                }
            } onCancel: {
                uploadSession.invalidateAndCancel()
            }
            try Self.check(response: response, data: responseData)
        } catch {
            if error is APIError { throw error }
            throw APIError.network(error)
        }
    }

    /// Requête authentifiée prête à être confiée à un autre client système,
    /// par exemple AVFoundation pour la lecture progressive d'une vidéo.
    func authenticatedRequest(_ endpoint: Endpoint) throws -> URLRequest {
        try request(for: endpoint, method: "GET")
    }

    // MARK: - Internes

    private func send(
        _ endpoint: Endpoint,
        method: String,
        httpBody: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Data, URLResponse) {
        var request = try request(for: endpoint, method: method)
        if let httpBody {
            request.httpBody = httpBody
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        do {
            return try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
    }

    private func request(for endpoint: Endpoint, method: String) throws -> URLRequest {
        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.path = endpoint.path
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        // Les ressources kDrive sont dynamiques. Une actualisation doit lire
        // l'état courant du serveur, pas une ancienne liste conservée par iOS.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = TokenStore.current() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if requiresAuth(endpoint) {
            throw APIError.notSignedIn
        }
        return request
    }

    private func uploadRequest(for url: URL, method: String) throws -> URLRequest {
        guard Self.isTrustedUploadURL(url) else { throw APIError.invalidURL }
        guard let token = TokenStore.current() else { throw APIError.notSignedIn }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Les sessions d'upload peuvent être réparties sur un hôte dédié.
    /// Ne jamais suivre une URL arbitraire : elle recevrait le jeton API.
    static func isTrustedUploadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "api.infomaniak.com"
            || host == "upload.kdrive.infomaniak.com"
            || host.hasSuffix(".upload.kdrive.infomaniak.com")
    }

    /// `/1/account` est appelé pendant la validation du token : accepter
    /// l'absence de token ne concernerait aucun autre endpoint de toute façon.
    private func requiresAuth(_ endpoint: Endpoint) -> Bool {
        !endpoint.path.hasPrefix("/1/")
    }

    private static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = decodeError(data: data)
            throw APIError.http(status: http.statusCode, code: apiError?.code, description: apiError?.description)
        }
    }

    private static func decodeError(data: Data) -> (code: String?, description: String?)? {
        guard let envelope = try? JSONDecoder.api.decode(ErrorEnvelope.self, from: data) else { return nil }
        return (envelope.error?.code, envelope.error?.description)
    }
}

/// Délégué isolé par transfert : il collecte la petite réponse JSON et remonte
/// les octets réellement envoyés par URLSession.
private final class UploadProgressDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var responseData = Data()

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progress(min(max(fraction, 0), 1))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    /// Empêche qu'une redirection ne transforme une URL d'upload validée en
    /// destination arbitraire tout en conservant l'en-tête d'autorisation.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url,
              APIClient.isTrustedUploadURL(redirectURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response {
            continuation.resume(returning: (responseData, response))
        } else {
            continuation.resume(throwing: APIError.invalidResponse)
        }
    }
}

private struct ErrorEnvelope: Decodable {
    struct Inner: Decodable {
        let code: String?
        let description: String?
    }

    let error: Inner?
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}
