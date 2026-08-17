import Foundation

enum APIError: LocalizedError {
    case notSignedIn
    case invalidURL
    case http(status: Int, code: String?, description: String?)
    case invalidResponse
    case decoding(Error)
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
            if let description, !description.isEmpty {
                return "\(description) (HTTP \(status)\(code.map { ", \($0)" } ?? ""))"
            }
            return "Erreur serveur HTTP \(status)\(code.map { " — \($0)" } ?? "")."
        case .invalidResponse:
            return "Réponse inattendue du serveur."
        case .decoding:
            return "Impossible d'interpréter la réponse du serveur."
        case let .network(error):
            return error.localizedDescription
        }
    }

    var isUnauthorized: Bool {
        if case let .http(status, _, _) = self { return status == 401 }
        return false
    }

    /// Erreurs pour lesquelles une nouvelle tentative est raisonnable sans
    /// demander une action utilisateur (réseau temporaire, limite ou serveur).
    var isRetryable: Bool {
        switch self {
        case let .http(status, _, _):
            return status == 408 || status == 429 || (500..<600).contains(status)
        case let .network(error):
            guard let urlError = error as? URLError else { return false }
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }
}
