import Foundation

extension Notification.Name {
    /// Émise uniquement avec l'empreinte du token qui a reçu un HTTP 401.
    static let apiUnauthorized = Notification.Name("com.orvian.api.unauthorized")
}

/// Client HTTP pour l'API Infomaniak (`https://api.infomaniak.com`).
///
/// Actor : toutes les requêtes décodent hors du MainActor, la vue ne touche
/// jamais le réseau directement.
actor APIClient {
    static let shared = APIClient()

    static let baseURL = URL(string: "https://api.infomaniak.com")!

    private let session: URLSession
    /// GET identiques actuellement en vol, par empreinte (compte + jeton,
    /// politique de cache, URL complète). Une même ressource demandée par
    /// deux vues en même temps ne part qu'une fois sur le réseau ; les
    /// appelants suivants attendent la réponse de la première.
    private let sharedGETs = SharedRequests<String, Data>()

    /// Session dédiée à l'API au lieu de `URLSession.shared` :
    /// - cache URLCache propre à Orvian, dimensionné pour que la revalidation
    ///   ETag/304 reste efficace — le cache partagé système, quelques Mo
    ///   partagés avec tout le téléphone, évince les réponses de listes
    ///   paginées et force leur re-téléchargement complet au retour dans un
    ///   dossier déjà consulté ;
    /// - huit connexions par hôte, comme le régulateur de miniatures.
    /// Les uploads utilisent une autre session partagée.
    init(session: URLSession = URLSession(configuration: APIClient.apiConfiguration)) {
        self.session = session
    }

    private static let apiConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 150 * 1024 * 1024,
            diskPath: "api-url-cache"
        )
        configuration.httpMaximumConnectionsPerHost = 8
        return configuration
    }()

    // MARK: - Requêtes

    /// Requête authentifiée renvoyant les données brutes (miniatures…).
    ///
    /// Politique de cache par défaut (`useProtocolCachePolicy`) : les listes
    /// et fiches peuvent être revalidées par ETag/Last-Modified (le serveur
    /// répond 304 sans re-transférer le corps quand rien n'a changé). Les
    /// appelants qui exigent un état strictement à jour passent
    /// `.reloadIgnoringLocalCacheData`.
    ///
    /// Les GET identiques lancés en parallèle sont dédoublonnés (coalescing) :
    /// la requête part une seule fois et chaque appelant reçoit la même
    /// réponse. Chaque appelant peut annuler son attente ; le réseau est
    /// annulé dès que plus aucun appelant n'en a besoin.
    func data(
        _ endpoint: Endpoint,
        method: String = "GET",
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> Data {
        let request = try request(for: endpoint, method: method, cachePolicy: cachePolicy)
        if method == "GET" {
            return try await coalescedData(for: request, measuredPath: endpoint.path)
        }
        let (data, response, _) = try await transmit(
            request: request,
            measuredMethod: method,
            measuredPath: endpoint.path
        )
        try Self.check(response: response, data: data, credentialFingerprint: Self.credentialFingerprint(for: request))
        return data
    }

    /// Dédoublonnage des GET concurrent : premier appelant = initiateur
    /// (la requête part réellement), appelants suivants = spectateurs de la
    /// même `Task`.
    private func coalescedData(for request: URLRequest, measuredPath: String) async throws -> Data {
        let fingerprint = Self.credentialFingerprint(for: request)
        let key = "\(fingerprint ?? "anon")|\(request.cachePolicy.rawValue)|\(request.url?.absoluteString ?? measuredPath)"
        return try await sharedGETs.value(for: key) { [self] in
            let (data, response, _) = try await self.transmit(
                request: request, measuredMethod: "GET", measuredPath: measuredPath
            )
            try Self.check(response: response, data: data, credentialFingerprint: fingerprint)
            return data
        }
    }

    /// Requête authentifiée décodée en JSON.
    func get<T: Decodable>(
        _ type: T.Type = T.self,
        _ endpoint: Endpoint,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> T {
        let data = try await self.data(endpoint, cachePolicy: cachePolicy)
        do {
            return try await ResponseDecoder.decode(T.self, from: data)
        } catch {
            if error is CancellationError { throw error }
            if let apiError = error as? APIError { throw apiError }
            throw APIError.decoding(error, raw: Data(data.prefix(16_384)))
        }
    }

    /// Requête « vide » (POST/DELETE renvoyant `{result, data}`).
    func sendEmpty(_ endpoint: Endpoint, method: String) async throws {
        try await send(endpoint, method: method, body: nil, contentType: nil)
    }

    /// Mutation avec corps optionnel (ex. DELETE groupé `{"file_ids": […]}`).
    /// Le retrait groupé de tags exige un corps JSON sur un DELETE, ce que
    /// `sendEmpty` ne permet pas. Lève une erreur si le statut n'est pas 2xx ;
    /// le contenu de la réponse est ignoré.
    func send(_ endpoint: Endpoint, method: String, body: Data?, contentType: String?) async throws {
        var request = try request(for: endpoint, method: method, cachePolicy: .reloadIgnoringLocalCacheData)
        if let body {
            request.httpBody = body
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response, _) = try await transmit(
            request: request,
            measuredMethod: method,
            measuredPath: endpoint.path
        )
        try Self.check(response: response, data: data, credentialFingerprint: Self.credentialFingerprint(for: request))
    }

    /// POST avec corps brut (JSON, octet-stream…). Lève une erreur si le
    /// statut HTTP n'est pas 2xx ; le contenu de la réponse est ignoré.
    func post(_ endpoint: Endpoint, body: Data, contentType: String) async throws {
        var request = try request(for: endpoint, method: "POST", cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response, _) = try await transmit(
            request: request,
            measuredMethod: "POST",
            measuredPath: endpoint.path
        )
        try Self.check(response: response, data: data, credentialFingerprint: Self.credentialFingerprint(for: request))
    }

    /// POST décodé, notamment pour l'ouverture et la fermeture des sessions
    /// d'upload où le corps de réponse fait partie de la confirmation.
    func postDecoded<T: Decodable>(
        _ type: T.Type = T.self,
        _ endpoint: Endpoint,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> T {
        var request = try request(for: endpoint, method: "POST", cachePolicy: .reloadIgnoringLocalCacheData)
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response, _) = try await transmit(
            request: request,
            measuredMethod: "POST",
            measuredPath: endpoint.path
        )
        try Self.check(response: response, data: data, credentialFingerprint: Self.credentialFingerprint(for: request))
        do {
            return try await ResponseDecoder.decode(T.self, from: data)
        } catch {
            if error is CancellationError { throw error }
            if let apiError = error as? APIError { throw apiError }
            throw APIError.decoding(error, raw: Data(data.prefix(16_384)))
        }
    }

    /// PUT avec corps brut (JSON…). Lève une erreur si le statut HTTP n'est pas 2xx.
    func put(_ endpoint: Endpoint, body: Data, contentType: String = "application/json") async throws {
        var request = try request(for: endpoint, method: "PUT", cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response, _) = try await transmit(
            request: request,
            measuredMethod: "PUT",
            measuredPath: endpoint.path
        )
        try Self.check(response: response, data: data, credentialFingerprint: Self.credentialFingerprint(for: request))
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
        let credentialFingerprint = Self.credentialFingerprint(for: request)
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transferUpload(request: request, fileURL: fileURL, progress: progress)
        try Self.check(response: response, data: data, credentialFingerprint: credentialFingerprint)
        do {
            let envelope = try await ResponseDecoder.decode(DataResponse<DriveFile>.self, from: data)
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
            if error is CancellationError { throw error }
            if let apiError = error as? APIError { throw apiError }
            throw APIError.decoding(error, raw: Data(data.prefix(16_384)))
        }
    }

    /// Envoie un morceau vers l'URL dédiée renvoyée par `upload/session/start`.
    /// Cette URL reste contrôlée : seuls les hôtes Infomaniak autorisés peuvent
    /// recevoir l'en-tête Bearer de l'utilisateur. Le morceau est lu depuis un
    /// fichier temporaire, sans charger le morceau entier en RAM.
    func uploadFile(
        to url: URL,
        fileURL: URL,
        contentType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        var request = try uploadRequest(for: url, method: "POST")
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let credentialFingerprint = Self.credentialFingerprint(for: request)

        let (data, response) = try await transferUpload(request: request, fileURL: fileURL, progress: progress)
        try Self.check(response: response, data: data, credentialFingerprint: credentialFingerprint)
        return data
    }

    /// Transfert réel d'un upload : la tâche est créée suspendue, enregistrée
    /// auprès du délégué partagé, puis démarrée. La session est partagée (la
    /// réutilisation des connexions est possible d'un transfert à l'autre,
    /// sans recréer une session pour chaque morceau).
    /// L'annulation ne touche que la tâche, jamais la session : `task.cancel()`
    /// est toujours sûr, même sur une `Task` Swift déjà annulée à l'entrée
    /// (l'ancien code appelait `invalidateAndCancel()` avant la création de la
    /// tâche, et `resume()` sur une session invalidée levait une exception).
    private func transferUpload(
        request: URLRequest,
        fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        let task = uploadSession.uploadTask(with: request, fromFile: fileURL)
        let completion = UploadTransferMultiplexer.shared.register(
            taskIdentifier: task.taskIdentifier,
            progress: progress
        )
        defer { UploadTransferMultiplexer.shared.remove(taskIdentifier: task.taskIdentifier) }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            if error is APIError { throw error }
            throw APIError.network(error)
        }
    }

    // MARK: - Internes

    /// Transmission réelle d'une requête construite : mesure Perf (durée,
    /// drapeau cache via la sonde de métriques) puis renvoi des données.
    private func transmit(
        request: URLRequest,
        measuredMethod: String,
        measuredPath: String
    ) async throws -> (Data, URLResponse, String?) {
        let credentialFingerprint = Self.credentialFingerprint(for: request)
        let probe = CacheProbeDelegate()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await PerfTimer.measure(method: measuredMethod, path: measuredPath) {
                let (data, response) = try await session.data(for: request, delegate: probe)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ((data, response), status: status, bytes: data.count, fromCache: probe.fromCache)
            }
            return (data, response, credentialFingerprint)
        } catch {
            throw APIError.network(error)
        }
    }

    private func request(
        for endpoint: Endpoint,
        method: String,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) throws -> URLRequest {
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
        // Les GET profitent de la revalidation HTTP (ETag → 304) ; les
        // mutations passent explicitement `.reloadIgnoringLocalCacheData`.
        request.cachePolicy = cachePolicy
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

    private static func check(response: URLResponse, data: Data, credentialFingerprint: String?) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, let credentialFingerprint {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .apiUnauthorized, object: credentialFingerprint)
                }
            }
            let apiError = decodeError(data: data)
            throw APIError.http(status: http.statusCode, code: apiError?.code, description: apiError?.description)
        }
    }

    private static func credentialFingerprint(for request: URLRequest) -> String? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ")
        else { return nil }
        return TokenStore.fingerprint(of: String(authorization.dropFirst("Bearer ".count)))
    }

    private static func decodeError(data: Data) -> (code: String?, description: String?)? {
        guard data.count <= 16_384, let envelope = try? JSONDecoder.api.decode(ErrorEnvelope.self, from: data) else { return nil }
        return (envelope.error?.code, envelope.error?.description)
    }
}

/// Session d'upload partagée par tous les transferts : chaque morceau (comme
/// chaque fichier envoyé en direct) peut réutiliser les connexions de son
/// hôte. Le gain dépend du réseau et du serveur ; le nombre de négociations
/// TLS évitées n'est pas mesuré ici. Elle n'est jamais invalidée : elle vit pendant
/// toute la durée du processus.
private let uploadSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    // Autant de connexions que d'envois simultanés (`UploadManager`), ni plus
    // ni moins : une tâche supplémentaire attendrait une connexion libre.
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
        configuration: configuration,
        delegate: UploadTransferMultiplexer.shared,
        // File série : les rappels du délégué s'exécutent l'un après l'autre.
        delegateQueue: nil
    )
}()

/// Délégué unique de la session d'upload partagée : il route la progression et
/// la fin de chaque transfert vers son appelant, identifié par
/// `taskIdentifier`. Les tâches sont créées suspendues, enregistrées, puis
/// démarrées : aucun événement de session ne peut arriver avant
/// l'enregistrement.
private final class UploadTransferMultiplexer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = UploadTransferMultiplexer()

    private struct Transfer {
        let progress: @Sendable (Double) -> Void
        let completion = TransferCompletion<(Data, URLResponse)>()
        var responseData = Data()
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    /// Enregistre une tâche avant son démarrage et renvoie le rendez-vous sur
    /// lequel l'appelant installera sa continuation.
    func register(
        taskIdentifier: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) -> TransferCompletion<(Data, URLResponse)> {
        let transfer = Transfer(progress: progress)
        let completion = transfer.completion
        lock.lock()
        transfers[taskIdentifier] = transfer
        lock.unlock()
        return completion
    }

    /// Oublie la tâche (réussite, échec ou annulation de l'appelant).
    func remove(taskIdentifier: Int) {
        lock.lock()
        transfers.removeValue(forKey: taskIdentifier)
        lock.unlock()
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
        lock.lock()
        let progress = transfers[task.taskIdentifier]?.progress
        lock.unlock()
        progress?(min(max(fraction, 0), 1))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        transfers[dataTask.taskIdentifier]?.responseData.append(data)
        lock.unlock()
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
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        if let error {
            transfer?.completion.finish(.failure(error))
        } else if let response = task.response {
            transfer?.completion.finish(.success((transfer?.responseData ?? Data(), response)))
        } else {
            transfer?.completion.finish(.failure(APIError.invalidResponse))
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

/// Sonde par requête : les métriques URLSession indiquent si la réponse
/// finale a été servie depuis le cache local (entrée encore fraîche, ou
/// revalidée par un 304 sans re-transfert du corps).
private final class CacheProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var fromCache = false

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        fromCache = metrics.transactionMetrics.contains { transaction in
            transaction.resourceFetchType == .localCache
                || (transaction.response as? HTTPURLResponse)?.statusCode == 304
        }
    }
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}
