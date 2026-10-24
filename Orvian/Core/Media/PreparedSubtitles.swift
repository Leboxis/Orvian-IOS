import Foundation
import NaturalLanguage

struct PreparedSubtitleKey: Codable, Hashable, Sendable {
    let credential: String
    let driveID: Int
    let fileID: Int
    let size: Int?
    let modifiedAt: Double?
    let updatedAt: Double?
    let source: SubtitleSourceLanguage
    let version: Int

    static var currentVersion: Int {
        if #available(iOS 26.4, *) { return 8 }
        return 7
    }

    init(credential: String, driveID: Int, file: DriveFile, source: SubtitleSourceLanguage) {
        self.credential = credential
        self.driveID = driveID
        fileID = file.id
        size = file.size
        modifiedAt = file.lastModifiedAt
        updatedAt = file.updatedAt
        self.source = source
        version = Self.currentVersion
    }
}

struct PreparedSubtitle: Codable, Equatable, Sendable {
    let start: Double
    var end: Double
    var original: String
    var french: String
    var needsReview: Bool? = nil
}

struct PreparedSubtitles: Codable, Equatable, Sendable {
    let key: PreparedSubtitleKey
    let createdAt: Date
    let cues: [PreparedSubtitle]

    var isValid: Bool {
        guard key.version == PreparedSubtitleKey.currentVersion, !cues.isEmpty, cues.count <= 50_000 else { return false }
        var previousEnd = -Double.infinity
        for cue in cues {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0,
                  cue.end > cue.start, cue.start >= previousEnd,
                  !cue.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cue.french.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            previousEnd = cue.end
        }
        return true
    }

    /// Recherche sur la timeline source, sans tolérance d'avance ni délai
    /// d'affichage. Fonctionne à toute vitesse et après un seek dans les deux sens.
    func cue(at time: Double, mode: SubtitleMode) -> SubtitleCue? {
        guard mode != .off, time.isFinite else { return nil }
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let selected = cues[low - 1]
        guard time < selected.end else { return nil }
        return SubtitleCue(start: selected.start, end: selected.end,
                           text: mode == .french ? selected.french : selected.original,
                           isFinal: true, isTranslated: mode == .french && key.source != .french)
    }
}

struct PreparedSpeechSpan: Sendable {
    let start: Double
    let end: Double
    var text: String
    var beginsResult = false
    var confidence: Double? = nil
    var alternatives: [String] = []
}

/// Phrase complète + intervalle reconnu. NLTokenizer évite de couper aux
/// abréviations ; seules les phrases très longues/sans ponctuation sont bornées.
enum PreparedSentenceBuilder {
    static func make(_ spans: [PreparedSpeechSpan], source: SubtitleSourceLanguage) throws -> [PreparedSubtitle] {
        guard spans.count <= 250_000 else { throw PreparedSubtitleError.tooLarge }
        var text = ""
        var mapped: [(range: Range<Int>, span: PreparedSpeechSpan)] = []
        var offset = 0
        for originalSpan in spans {
            var span = originalSpan
            guard span.start.isFinite, span.end.isFinite, span.start >= 0,
                  span.end > span.start else { throw PreparedSubtitleError.timing }
            if span.beginsResult, let last = text.last, !last.isWhitespace,
               let first = span.text.first, !first.isWhitespace {
                span.text = " " + span.text
            }
            let length = span.text.utf16.count
            mapped.append((offset..<(offset + length), span))
            text += span.text
            offset += length
            guard offset <= 8_000_000 else { throw PreparedSubtitleError.tooLarge }
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: source.rawValue))
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        var sentences: [PreparedSubtitle] = []
        var cursor = 0
        for range in ranges {
            let lower = range.lowerBound.utf16Offset(in: text)
            let upper = range.upperBound.utf16Offset(in: text)
            while cursor < mapped.count, mapped[cursor].range.upperBound <= lower { cursor += 1 }
            var index = cursor
            var words: [PreparedSpeechSpan] = []
            while index < mapped.count, mapped[index].range.lowerBound < upper {
                let item = mapped[index]
                let left = max(lower, item.range.lowerBound)
                let right = min(upper, item.range.upperBound)
                if right > left {
                    let substring = (text as NSString).substring(with: NSRange(location: left, length: right - left))
                    words.append(PreparedSpeechSpan(start: item.span.start, end: item.span.end, text: substring, confidence: item.span.confidence))
                }
                index += 1
            }
            var pending: PreparedSubtitle?
            for word in words {
                if let current = pending,
                   word.start - current.end > 0.8 || current.original.count >= 600 || current.end - current.start >= 30 {
                    append(current, to: &sentences)
                    pending = nil
                }
                if var current = pending {
                    current.needsReview = current.needsReview == true || PreparedSpeechRefinement.confidence(word.confidence).map { $0 < PreparedSpeechRefinement.uncertaintyThreshold } == true
                    current.original += word.text
                    current.end = max(current.end, word.end)
                    pending = current
                } else {
                    pending = PreparedSubtitle(start: word.start, end: word.end, original: word.text, french: "",
                        needsReview: PreparedSpeechRefinement.confidence(word.confidence).map { $0 < PreparedSpeechRefinement.uncertaintyThreshold })
                }
            }
            if let pending { append(pending, to: &sentences) }
        }
        guard !sentences.isEmpty else { throw PreparedSubtitleError.noSpeech }
        return sentences
    }

    private static func append(_ cue: PreparedSubtitle, to result: inout [PreparedSubtitle]) {
        let original = cue.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        if let last = result.last, cue.start < last.end {
            // Des attributs Speech parfois grossiers couvrent plusieurs phrases.
            // Les réunir préserve le texte et les vraies bornes sans inventer
            // des temps intermédiaires pour la traduction.
            result[result.count - 1].needsReview = last.needsReview == true || cue.needsReview == true
            result[result.count - 1].original += " " + original
            result[result.count - 1].end = max(last.end, cue.end)
        } else {
            result.append(PreparedSubtitle(start: cue.start, end: cue.end, original: original, french: "", needsReview: cue.needsReview))
        }
    }
}

enum PreparedSubtitleError: Error, LocalizedError {
    case contextAlignment, source, noAudio, multipleTracks, timing, noSpeech, tooLarge, unavailable, busy, download, storage, incomplete
    var errorDescription: String? {
        switch self {
        case .contextAlignment: "Le moteur n’a pas conservé les repères nécessaires pour séparer la phrase de son contexte. Aucun résultat partiel n’a été enregistré."
        case .source: "Cette vidéo ne permet pas une analyse audio locale complète."
        case .noAudio: "La vidéo ne contient pas de piste audio."
        case .multipleTracks: "Plusieurs pistes audio : préparez une vidéo avec une seule piste pour éviter de traduire la mauvaise voix."
        case .timing: "Horodatages audio incohérents : préparation arrêtée pour éviter des sous-titres décalés."
        case .noSpeech: "Aucune parole exploitable n’a été reconnue."
        case .tooLarge: "La préparation dépasse les limites de stockage ou de taille prises en charge."
        case .unavailable: "La reconnaissance de cette langue n’est pas disponible sur cet appareil."
        case .busy: "Une autre préparation audio est en cours."
        case .download: "Impossible de télécharger la vidéo. Réessayez avec une connexion stable."
        case .storage: "Impossible d’enregistrer les sous-titres. Vérifiez l’espace disponible."
        case .incomplete: "La traduction n’est pas complète. Aucun résultat partiel n’a été enregistré."
        }
    }
}
