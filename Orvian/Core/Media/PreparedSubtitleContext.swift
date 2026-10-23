import Foundation
import CoreMedia
import Speech

/// Recorded-video context: eight seconds before and four seconds after, with
/// whole boundary sentences. Never use the player's wall clock for captions.
/// https://developer.apple.com/documentation/translation/translationsession/request/attributedsourcetext
struct PreparedSubtitleContext {
    let text: AttributedString
    let ranges: [CMTimeRange]
    let identifiers: [URL]
    let currentIndex: Int
    let currentSource: String
    private let originals: [String]
    var currentRange: CMTimeRange { ranges[currentIndex] }
    var hasContext: Bool { ranges.count > 1 }

    init(cues: [PreparedSubtitle], index: Int) {
        precondition(cues.indices.contains(index))
        var first = index
        var last = index
        var length = cues[index].original.utf16.count
        while first > 0, cues[first - 1].end > cues[index].start - 8,
              length + cues[first - 1].original.utf16.count <= 6000 {
            first -= 1
            length += cues[first].original.utf16.count
        }
        while last + 1 < cues.count, cues[last + 1].start < cues[index].end + 4,
              length + cues[last + 1].original.utf16.count <= 6000 {
            last += 1
            length += cues[last].original.utf16.count
        }
        currentIndex = index - first
        currentSource = cues[index].original
        originals = (first...last).map { cues[$0].original }
        ranges = (first...last).map {
            CMTimeRange(start: CMTime(seconds: cues[$0].start, preferredTimescale: 60_000),
                        end: CMTime(seconds: cues[$0].end, preferredTimescale: 60_000))
        }
        // Foundation links are supported translation attributes. These internal
        // identifiers are never opened or displayed; they mark sentence identity
        // independently of Apple's best-effort speech timing attributes.
        identifiers = (first...last).map { URL(string: "orvian-caption://sentence/\($0)")! }
        text = Self.attributed(originals: originals, ranges: ranges, identifiers: identifiers,
                               indices: Array(originals.indices), includeTimes: true)
    }

    private static func attributed(originals: [String], ranges: [CMTimeRange], identifiers: [URL],
                                   indices: [Int], includeTimes: Bool) -> AttributedString {
        var output = AttributedString()
        for index in indices {
            if !output.characters.isEmpty { output += AttributedString(" ") }
            var sentence = AttributedString(originals[index])
            sentence.link = identifiers[index]
            if includeTimes { sentence[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = ranges[index] }
            output += sentence
        }
        return output
    }

    /// Retry with only the nearest complete sentence on each side and link
    /// identity. This retains context when speech attributes are discarded.
    private var compactText: AttributedString {
        Self.attributed(originals: originals, ranges: ranges, identifiers: identifiers,
                        indices: Array(max(0, currentIndex - 1)...min(ranges.count - 1, currentIndex + 1)),
                        includeTimes: false)
    }

    func currentTranslation(from translated: AttributedString?) throws -> String {
        guard let translated else { throw PreparedSubtitleError.contextAlignment }
        var output = ""
        var started = false
        var closed = false
        var sawContext = false
        for run in translated.runs {
            let fragment = String(translated[run.range].characters)
            let meaningful = !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let link = run.link
            let time = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            let linkedIndex = link.flatMap { identifiers.firstIndex(of: $0) }
            let timedIndex = time.flatMap { value in ranges.firstIndex { CMTimeRangeEqual($0, value) } }
            if let link, !identifiers.contains(link) { throw PreparedSubtitleError.contextAlignment }
            if let linkedIndex, let timedIndex, linkedIndex != timedIndex { throw PreparedSubtitleError.contextAlignment }
            // A merged time range covering the current sentence is ambiguous,
            // even if another attribute tries to identify just one sentence.
            if let time, timedIndex == nil,
               CMTimeRangeGetIntersection(time, otherRange: currentRange).duration.seconds > 0 {
                throw PreparedSubtitleError.contextAlignment
            }
            let identified = linkedIndex ?? timedIndex
            let isCurrent = identified == currentIndex
            var isContext = identified.map { $0 != currentIndex } ?? false
            if identified == nil, let time, time.start.seconds.isFinite, time.end.seconds.isFinite,
               time.duration.seconds > 0,
               time.start.seconds >= ranges[0].start.seconds,
               time.end.seconds <= ranges[ranges.count - 1].end.seconds,
               time.end.seconds <= currentRange.start.seconds || time.start.seconds >= currentRange.end.seconds {
                isContext = true
            }
            if isCurrent {
                guard !closed else { throw PreparedSubtitleError.contextAlignment }
                started = true
                output += fragment
            } else if isContext {
                if meaningful { sawContext = true; if started { closed = true } }
            } else {
                guard !meaningful else { throw PreparedSubtitleError.contextAlignment }
                if started, !closed { output += fragment }
            }
        }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, !hasContext || sawContext else { throw PreparedSubtitleError.contextAlignment }
        return result
    }

    @MainActor
    func translateCurrent(
        contextual: (AttributedString) async throws -> AttributedString?,
        isolated: (String) async throws -> String
    ) async throws -> PreparedContextTranslation {
        try Task.checkCancellation()
        if hasContext {
            for (attempt, input) in [text, compactText].enumerated() {
                let translated = try await contextual(input)
                try Task.checkCancellation()
                do {
                    return PreparedContextTranslation(text: try currentTranslation(from: translated),
                                                      usedContext: true, reducedContext: attempt > 0)
                } catch PreparedSubtitleError.contextAlignment {
                    // Only alignment loss retries. Translation errors and
                    // cancellation propagate; never guess a sentence boundary.
                }
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

struct PreparedContextTranslation {
    let text: String
    let usedContext: Bool
    var reducedContext = false
}
