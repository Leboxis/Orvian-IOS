import Foundation

@main struct PreparedSubtitleDiagnosticsChecks {
    static func main() {
        let secret = "https://private.example/video.mkv?token=DO_NOT_DISPLAY"
        let underlying = NSError(domain: "kAFAssistantErrorDomain", code: 1101,
                                 userInfo: [NSLocalizedDescriptionKey: secret])
        let error = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSLocalizedDescriptionKey: secret,
            NSFilePathErrorKey: "/private/user/movie.mkv",
            NSURLErrorFailingURLErrorKey: URL(string: secret)!
        ])
        for stage in PreparedSubtitleStage.allCases {
            let message = stage.failureMessage(for: error)
            assert(message.contains(stage.rawValue))
            assert(message.contains("NSCocoaErrorDomain (256)"))
            assert(message.contains("kAFAssistantErrorDomain (1101)"))
            assert(!message.contains("private") && !message.contains("DO_NOT_DISPLAY"))
            assert(!message.contains("Vérifiez les modèles"))
        }
        let unknown = NSError(domain: secret, code: -42, userInfo: [:])
        let redacted = PreparedSubtitleStage.transcription.failureMessage(for: unknown)
        assert(redacted.contains("Erreur système (-42)"))
        assert(!redacted.contains(secret))
        let friendly = PreparedSubtitleStage.audio.failureMessage(for: error, explanation: "Plusieurs pistes audio.")
        assert(friendly.hasPrefix("Plusieurs pistes audio."))
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [:])
        assert(PreparedSubtitleStage.download.failureMessage(for: network).contains("NSURLErrorDomain (-1001)"))
        print("Prepared subtitle diagnostics: stage, codes, underlying error and privacy checks passed")
    }
}
