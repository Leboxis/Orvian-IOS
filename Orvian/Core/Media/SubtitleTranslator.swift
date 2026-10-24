import Foundation
import Translation

/// Traductions vers le français pour les sous-titres.
///
/// La session `TranslationSession` fournie par `.translationTask` ne doit pas
/// survivre à la vue qui l'a créée (Apple documente un `fatalError`). Une fois
/// les langues installées, on utilise donc une session directe
/// `installedSource:target:`, détenue par l'appelant et utilisable hors SwiftUI.
///
/// Contrainte documentée : `installedSource:target:` exige que les deux langues
/// soient **déjà installées** sur l'appareil, sinon chaque traduction rejette.
/// `translate()` interroge donc `LanguageAvailability` avant de créer la session
/// et refuse d'emblée si le modèle manque, au lieu d'échouer à chaque phrase.
actor SubtitleTranslator {
    private var session: TranslationSession?
    private var failures = 0
    private var source: SubtitleSourceLanguage?

    /// Langues installées ? Sinon, la préparation doit passer par l'interface.
    static func availability(source: SubtitleSourceLanguage = .english) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: source.rawValue),
            to: Locale.Language(identifier: "fr")
        )
    }

    /// Interroge le système : la paire choisie vers le français est-elle installée ?
    func isInstalled(source: SubtitleSourceLanguage) async -> Bool {
        await Self.availability(source: source) == .installed
    }

    func translate(_ text: String, source: SubtitleSourceLanguage) async throws -> String {
        if source == .french { return text }
        if self.source != source { reset(); self.source = source }
        try Task.checkCancellation()
        if session == nil {
            // Une installation absente est irrécupérable ici : le diagnostic doit
            // être explicite plutôt qu'un échec répété à chaque phrase.
            guard await isInstalled(source: source) else { throw SubtitleTranslationError.notInstalled }
            session = TranslationSession(
                installedSource: Locale.Language(identifier: source.rawValue),
                target: Locale.Language(identifier: "fr")
            )
        }
        guard let activeSession = session else { throw SubtitleTranslationError.unavailable }
        do {
            let response = try await activeSession.translate(text)
            failures = 0
            return response.targetText
        } catch let translationError as SubtitleTranslationError {
            // Le modèle a disparu entre-temps : repartir d'une session neuve à la
            // prochaine phrase, avec un diagnostic exact.
            self.session = nil
            throw translationError
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
        source = nil
    }
}

enum SubtitleTranslationError: Error, LocalizedError {
    case unavailable, failed, notInstalled

    var errorDescription: String? {
        switch self {
        case .unavailable: "Traduction indisponible sur cet appareil."
        case .failed: "La traduction n’a pas abouti. Réessayez, ou coupez puis rétablissez le mode français."
        case .notInstalled: "Modèle de traduction français absent. Activez le mode français pour le télécharger."
        }
    }
}
