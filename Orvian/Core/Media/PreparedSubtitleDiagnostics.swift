import Foundation
#if canImport(Speech)
import Speech
#endif

/// Only stage identifiers and public system codes are exposed, never userInfo,
/// localized system descriptions, source URLs, file paths or recognized text.
enum PreparedSubtitleStage: String, CaseIterable, Sendable {
    case download = "téléchargement de la source"
    case audio = "ouverture et décodage audio"
    case speechModels = "préparation du modèle de transcription Apple"
    case speechPreparation = "initialisation de l’analyseur Apple"
    case transcription = "transcription Apple"
    case speechFinishing = "finalisation de la transcription Apple"
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
            let name = Self.speechCodeName(for: value).map { " [\($0)]" } ?? ""
            codes.append("\(domain) (\(value.code))\(name)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(explanation ?? "La préparation a échoué.")\nÉtape : \(rawValue).\nCode : \(codes.joined(separator: " → "))"
    }

    private static func speechCodeName(for error: NSError) -> String? {
        #if canImport(Speech)
        guard error.domain == SFSpeechErrorDomain else { return nil }
        if #available(iOS 26, macOS 26, *) {
            // Compare the SDK's public constants, never guess a numeric mapping.
            let names: [(SFSpeechError.Code, String)] = [
                (.audioDisordered, "audioDisordered"),
                (.unexpectedAudioFormat, "unexpectedAudioFormat"),
                (.incompatibleAudioFormats, "incompatibleAudioFormats"),
                (.noModel, "noModel"),
                (.assetLocaleNotAllocated, "assetLocaleNotAllocated"),
                (.tooManyAssetLocalesAllocated, "tooManyAssetLocalesAllocated"),
                (.cannotAllocateUnsupportedLocale, "cannotAllocateUnsupportedLocale"),
                (.moduleOutputFailed, "moduleOutputFailed"),
                (.insufficientResources, "insufficientResources"),
                (.internalServiceError, "internalServiceError"),
                (.audioReadFailed, "audioReadFailed"),
                (.timeout, "timeout"),
                (.missingParameter, "missingParameter")
            ]
            if let name = names.first(where: { $0.0.rawValue == error.code })?.1 { return name }
        }
        #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *), error.code == SFSpeechError.Code.cannotConfigureAudioSystem.rawValue {
            return "cannotConfigureAudioSystem"
        }
        #endif
        return "code Speech non reconnu par ce SDK"
        #else
        return nil
        #endif
    }

    private static let publicDomains: Set<String> = [
        NSURLErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain,
        "AVFoundationErrorDomain", "SFSpeechErrorDomain", "SpeechErrorDomain",
        "kAFAssistantErrorDomain", "kLSRErrorDomain", "Speech.SpeechError",
        "TranslationErrorDomain", "Translation.TranslationError", "Orvian.PreparedSubtitleError"
    ]
}
