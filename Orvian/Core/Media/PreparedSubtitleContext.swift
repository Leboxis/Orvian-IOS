import Foundation
import CoreMedia
import Speech

/// Une requête unique : phrases précédentes dans la fenêtre de huit secondes
/// + phrase courante. Les phrases à cheval sur la borne restent entières.
/// L'attribut Speech documenté par Apple permet de retrouver la traduction
/// courante sans traduire des marqueurs visibles ni deviner un découpage.
/// https://developer.apple.com/documentation/translation/translationsession/request/attributedsourcetext
struct PreparedSubtitleContext {
    let text: AttributedString
    let ranges: [CMTimeRange]
    let currentSource: String
    var currentRange: CMTimeRange { ranges[ranges.count - 1] }
    var hasContext: Bool { ranges.count > 1 }

    init(cues: [PreparedSubtitle], index: Int) {
        precondition(cues.indices.contains(index))
        let lowerBound = cues[index].start - 8
        var first = index
        while first > 0, cues[first - 1].end > lowerBound { first -= 1 }
        var text = AttributedString()
        var ranges: [CMTimeRange] = []
        for position in first...index {
            if position != first { text += AttributedString(" ") }
            let cue = cues[position]
            let range = CMTimeRange(start: CMTime(seconds: cue.start, preferredTimescale: 60_000),
                                    end: CMTime(seconds: cue.end, preferredTimescale: 60_000))
            var sentence = AttributedString(cue.original)
            sentence[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = range
            text += sentence
            ranges.append(range)
        }
        self.text = text
        self.ranges = ranges
        currentSource = cues[index].original
    }

    /// Refuser une attribution perdue/ambiguë plutôt que d'afficher les huit
    /// secondes de contexte à nouveau au temps de la phrase courante.
    func currentTranslation(from translated: AttributedString?) throws -> String {
        guard let translated else { throw PreparedSubtitleError.contextAlignment }
        var seen = Set<Int>()
        var output = ""
        var started = false
        var closed = false
        for run in translated.runs {
            let fragment = String(translated[run.range].characters)
            let meaningful = !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard let time = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                guard !meaningful else { throw PreparedSubtitleError.contextAlignment }
                if started, !closed { output += fragment }
                continue
            }
            guard let index = ranges.firstIndex(where: { CMTimeRangeEqual($0, time) }) else {
                throw PreparedSubtitleError.contextAlignment
            }
            if meaningful { seen.insert(index) }
            if index == ranges.count - 1 {
                guard !closed else { throw PreparedSubtitleError.contextAlignment }
                started = true
                output += fragment
            } else if started, meaningful {
                closed = true
            }
        }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard seen.count == ranges.count, !result.isEmpty else { throw PreparedSubtitleError.contextAlignment }
        return result
    }
}

struct PreparedContextTranslation {
    let text: String
    let usedContext: Bool
}

extension PreparedSubtitleContext {
    /// Apple preserves attributed timing on a best-effort basis, not as a
    /// guarantee. Never save the whole contextual response as the current cue.
    /// https://developer.apple.com/documentation/translation/translationsession/request/attributedsourcetext
    @MainActor
    func translateCurrent(
        contextual: (AttributedString) async throws -> AttributedString?,
        isolated: (String) async throws -> String
    ) async throws -> PreparedContextTranslation {
        try Task.checkCancellation()
        if hasContext {
            let translated = try await contextual(text)
            try Task.checkCancellation()
            do {
                return PreparedContextTranslation(text: try currentTranslation(from: translated), usedContext: true)
            } catch PreparedSubtitleError.contextAlignment {
                // Retry only the current source sentence. Do not guess a split,
                // reuse untranslated English, or swallow translation errors.
            }
        }
        try Task.checkCancellation()
        let translated = try await isolated(currentSource)
        try Task.checkCancellation()
        let result = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PreparedSubtitleError.incomplete }
        return PreparedContextTranslation(text: result, usedContext: false)
    }
}
