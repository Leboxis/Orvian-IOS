import Foundation
import Translation

/// Traductions anglais → français pour les sous-titres.
///
/// La session `TranslationSession` fournie par `.translationTask` ne doit pas
/// survivre à la vue qui l'a créée (Apple documente un `fatalError`). Une fois
/// les langues installées, on utilise donc une session directe
/// `installedSource:target:`, détenue par l'appelant et utilisable hors SwiftUI.
actor SubtitleTranslator {
    private var session: TranslationSession?
    private var failures = 0

    /// Langues installées ? Sinon, la préparation doit passer par l'interface.
    static func availability() async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: "en"),
            to: Locale.Language(identifier: "fr")
        )
    }

    /// Installe la session une seule fois. Sans langues installées, la
    /// traduction échouera : l'appelant doit avoir préparé les modèles.
    func prepare() {
        guard session == nil else { return }
        session = TranslationSession(
            installedSource: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "fr")
        )
    }

    func translate(_ text: String) async throws -> String {
        if session == nil { prepare() }
        guard let session else { throw SubtitleTranslationError.unavailable }
        do {
            let response = try await session.translate(text)
            failures = 0
            return response.targetText
        } catch {
            failures += 1
            // Une session devenue inutilisable (modèle supprimé, compte changé)
            // est recréée à la tentative suivante, sans arrêter la lecture.
            if failures >= 2 { self.session = nil }
            throw SubtitleTranslationError.failed
        }
    }

    func reset() {
        session = nil
        failures = 0
    }
}

enum SubtitleTranslationError: Error, LocalizedError {
    case unavailable, failed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Traduction indisponible sur cet appareil."
        case .failed: "La traduction n’a pas abouti. Le modèle français est peut-être absent."
        }
    }
}
