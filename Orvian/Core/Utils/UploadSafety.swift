import Foundation

/// Une réponse perdue ne prouve pas que le fichier n'a pas été créé.
enum UploadSafety {
    static func mayRetryDirectUpload(_ error: Error) -> Bool {
        // Seul un refus explicite pour limitation de débit autorise le rejeu.
        guard let apiError = error as? APIError,
              case let .http(status, _, _) = apiError else { return false }
        return status == 429
    }

    static func outcomeMayBeUnknown(_ error: Error) -> Bool {
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
