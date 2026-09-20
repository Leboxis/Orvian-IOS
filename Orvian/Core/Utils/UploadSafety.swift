import Foundation

/// Une réponse perdue ne prouve pas que le fichier n'a pas été créé.
enum UploadSafety {
    /// Vrai si l'erreur représente une annulation explicite (utilisateur,
    /// déconnexion) — jamais un doute sur le résultat côté serveur.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if case let .network(underlying) = error as? APIError {
            return (underlying as? URLError)?.code == .cancelled
        }
        return false
    }

    static func mayRetryDirectUpload(_ error: Error) -> Bool {
        // Seul un refus explicite pour limitation de débit autorise le rejeu.
        guard let apiError = error as? APIError,
              case let .http(status, _, _) = apiError else { return false }
        return status == 429
    }

    static func outcomeMayBeUnknown(_ error: Error) -> Bool {
        // Une annulation volontaire n'a rien d'inconnu : rien n'a été envoyé.
        if isCancellation(error) { return false }
        guard let error = error as? APIError else { return true }
        switch error {
        case .network, .invalidResponse, .decoding: return true
        case let .http(status, _, _): return status == 408 || status >= 500
        case .notSignedIn, .invalidURL: return false
        }
    }
}

struct UploadOutcomeUnknown: LocalizedError {
    var errorDescription: String? {
        "Le fichier a peut-être été enregistré dans kDrive, mais sa confirmation n’a pas été reçue. Vérifiez le dossier de destination avant de l’importer à nouveau pour éviter un doublon."
    }
}
