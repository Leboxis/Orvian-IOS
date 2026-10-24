import Foundation

/// Only stage identifiers and numeric system codes are exposed, never userInfo,
/// localized system descriptions, source URLs, file paths or recognized text.
enum PreparedSubtitleStage: String, CaseIterable, Sendable {
    case download = "téléchargement de la source"
    case audio = "ouverture et décodage audio"
    case speechModels = "préparation du modèle de transcription Apple"
    case transcription = "transcription Apple"
    case translationModels = "préparation du modèle de traduction Apple"
    case translation = "traduction française"
    case saving = "enregistrement des sous-titres"

    func failureMessage(for error: Error, explanation: String? = nil) -> String {
        var codes: [String] = []
        var current: NSError? = error as NSError
        // Bound the chain: framework errors may contain repeated underlying errors.
        for _ in 0..<3 {
            guard let value = current else { break }
            let domain = Self.publicDomains.contains(value.domain) ? value.domain : "Erreur système"
            codes.append("\(domain) (\(value.code))")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(explanation ?? "La préparation a échoué.")\nÉtape : \(rawValue).\nCode : \(codes.joined(separator: " → "))"
    }

    private static let publicDomains: Set<String> = [
        NSURLErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain,
        "AVFoundationErrorDomain", "SFSpeechErrorDomain", "SpeechErrorDomain",
        "kAFAssistantErrorDomain", "kLSRErrorDomain", "Speech.SpeechError",
        "TranslationErrorDomain", "Translation.TranslationError", "Orvian.PreparedSubtitleError"
    ]
}
