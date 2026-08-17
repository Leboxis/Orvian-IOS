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

    /// PUT avec corps brut (JSON…). Lève une erreur si le statut HTTP n'est pas 2xx.
    func put(_ endpoint: Endpoint, body: Data, contentType: String = "application/json") async throws {
        let (data, response) = try await send(endpoint, method: "PUT", httpBody: body, contentType: contentType)
        try Self.check(response: response, data: data)
    }

    /// Upload d'un fichier local par streaming (évite le chargement du fichier en RAM).
    func uploadFile(_ endpoint: Endpoint, fileURL: URL, contentType: String) async throws {
        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.path = endpoint.path
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        if let token = TokenStore.current() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if requiresAuth(endpoint) {
            throw APIError.notSignedIn
        }

        do {
            let (data, response) = try await session.upload(for: request, fromFile: fileURL)
            try Self.check(response: response, data: data)
        } catch {
            if error is APIError {
                throw error
            }
            throw APIError.network(error)
        }
    }

    // MARK: - Internes

    private func send(
        _ endpoint: Endpoint,
        method: String,
        httpBody: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Data, URLResponse) {
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let httpBody {
            request.httpBody = httpBody
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let token = TokenStore.current() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if requiresAuth(endpoint) {
            throw APIError.notSignedIn
        }

        do {
            return try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
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
