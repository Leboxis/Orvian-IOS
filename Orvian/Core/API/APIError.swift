import Foundation

enum APIError: LocalizedError {
    case notSignedIn
    case invalidURL
    case http(status: Int, code: String?, description: String?)
    case invalidResponse
    case decoding(Error, raw: Data?)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Aucun token configuré. Ouvrez l'onglet Plus pour le définir."
        case .invalidURL:
            return "URL invalide."
        case let .http(status, code, description):
            if status == 401 {
                return "Token invalide ou expiré (\(status))."
            }
            if status == 429 {
                return "Trop de requêtes vers le serveur (429). Réessayez dans un instant."
            }
            if let description, !description.isEmpty {
                return "\(description) (HTTP \(status)\(code.map { ", \($0)" } ?? ""))"
            }
            return "Erreur serveur HTTP \(status)\(code.map { " — \($0)" } ?? "")."
        case .invalidResponse:
            return "Réponse inattendue du serveur."
        case let .decoding(error, raw):
            var message = "Impossible d'interpréter la réponse du serveur."
            if let path = Self.decodingPath(of: error) {
                message += " (champ : \(path))"
            }
            if let snippet = Self.firstElementSnippet(of: raw) {
                message += " — \(snippet)"
            }
            return message
        case let .network(error):
            return error.localizedDescription
        }
    }

    var isUnauthorized: Bool {
        if case let .http(status, _, _) = self { return status == 401 }
        return false
    }

    /// Un repli vers un autre endpoint a une chance de réussir : le endpoint
    /// est indisponible pour ce compte (403/404) ou sa réponse est illisible.
    /// Une panne réseau, un 401, un rate limit (429) ou une erreur serveur
    /// concernent tous les endpoints : relancer la cascade ne ferait que
    /// multiplier les requêtes vouées à l'échec (et aggraver un 429).
    var isFallbackCandidate: Bool {
        switch self {
        case let .http(status, _, _):
            return status == 403 || status == 404
        case .decoding, .invalidResponse:
            return true
        case .network, .notSignedIn, .invalidURL:
            return false
        }
    }

    /// Chemin du champ fautif d'un `DecodingError`, p.ex.
    /// `data[3].categories[0].categoryId`.
    private static func decodingPath(of error: Error) -> String? {
        guard let decodingError = error as? DecodingError else { return nil }
        let key: CodingKey?
        let context: DecodingError.Context
        switch decodingError {
        case let .keyNotFound(foundKey, foundContext):
            key = foundKey
            context = foundContext
        case let .typeMismatch(_, foundContext):
            key = nil
            context = foundContext
        case let .valueNotFound(_, foundContext):
            key = nil
            context = foundContext
        case let .dataCorrupted(foundContext):
            key = nil
            context = foundContext
        @unknown default:
            return nil
        }
        var segments = context.codingPath.map { segment in
            segment.intValue.map { "[\($0)]" } ?? segment.stringValue
        }
        if let key {
            segments.append(key.intValue.map { "[\($0)]" } ?? key.stringValue)
        }
        return segments.isEmpty ? nil : segments.joined(separator: ".")
    }

    /// Extrait du corps JSON brut un aperçu court du premier élément de la
    /// liste (`data[0].name` et sa clé `categories`) pour diagnostiquer les
    /// écarts de schéma entre les endpoints.
    private static func firstElementSnippet(of raw: Data?) -> String? {
        guard let raw,
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let data = object["data"]
        else { return nil }

        let first: [String: Any]?
        if let array = data as? [[String: Any]] {
            first = array.first
        } else if let files = (data as? [String: Any])?["files"] as? [[String: Any]] {
            first = files.first
        } else {
            first = nil
        }
        guard let first else { return "data vide" }

        let name = first["name"] as? String ?? "?"
        var snippet = "data[0].name=\(name) categories="
        if let categories = first["categories"] {
            if let compact = try? JSONSerialization.data(withJSONObject: categories, options: [.sortedKeys]),
               let string = String(data: compact, encoding: .utf8) {
                snippet += string
            } else {
                snippet += "<illisible>"
            }
        } else {
            snippet += "absent"
        }
        return String(snippet.prefix(400))
    }
}