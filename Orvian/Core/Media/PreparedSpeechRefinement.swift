import Foundation
import CoreMedia
import Speech

/// Confidence is a signal for review, not a probability that a word is correct.
/// https://developer.apple.com/documentation/speech/speechtranscriber/result
/// https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption/transcriptionconfidence
enum PreparedSpeechRefinement {
    static let uncertaintyThreshold = 0.65

    static func confidence(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    /// Bounded second pass: at most 12 windows / 180 s, each <= 30 s.
    /// Audio on both sides is kept to avoid recognizing a word in isolation.
    static func windows(for spans: [PreparedSpeechSpan], duration: Double) -> [CMTimeRange] {
        guard duration.isFinite, duration > 0 else { return [] }
        var windows: [(start: Double, end: Double)] = []
        for span in spans where confidence(span.confidence).map({ $0 < uncertaintyThreshold }) == true {
            guard span.start.isFinite, span.end.isFinite, span.start >= 0, span.end > span.start else { continue }
            let start = max(0, span.start - 8)
            let end = min(duration, span.end + 4, start + 30)
            guard end > start, span.end <= end else { continue }
            if let last = windows.last, start <= last.end, end - last.start <= 30 {
                windows[windows.count - 1].end = max(last.end, end)
            } else {
                guard windows.count < 12 else { break }
                windows.append((start, end))
            }
        }
        var budget = 180.0
        return windows.compactMap { window in
            let length = window.end - window.start
            guard length <= budget else { return nil }
            budget -= length
            return CMTimeRange(start: CMTime(seconds: window.start, preferredTimescale: 60_000),
                               duration: CMTime(seconds: length, preferredTimescale: 60_000))
        }
    }

    /// Preserve all original times and high-confidence words. A changed passage
    /// must agree with one of Apple's original alternatives AND the second pass.
    static func merge(original: [PreparedSpeechSpan], reread: [PreparedSpeechSpan]) -> [PreparedSpeechSpan] {
        let timed = reread.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        guard let lower = timed.map(\.start).min(), let upper = timed.map(\.end).max() else { return original }
        var output = original
        var first = 0
        while first < original.count {
            var end = first + 1
            while end < original.count, !original[end].beginsResult { end += 1 }
            guard original[end - 1].end >= lower - 0.12, original[first].start <= upper + 0.12 else {
                first = end
                continue
            }
            var proposal = Array(original[first..<end])
            var changed = false
            for local in proposal.indices {
                let word = proposal[local]
                guard let oldConfidence = confidence(word.confidence), oldConfidence < uncertaintyThreshold else { continue }
                let matches = timed.filter {
                    abs($0.start - word.start) <= 0.12 && abs($0.end - word.end) <= 0.12
                        && confidence($0.confidence).map { $0 >= oldConfidence + 0.15 } == true
                }
                guard matches.count == 1 else { continue }
                let replacement = matches[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !replacement.isEmpty else { continue }
                let leading = String(word.text.prefix(while: { $0.isWhitespace }))
                let trailing = String(word.text.reversed().prefix(while: { $0.isWhitespace }).reversed())
                proposal[local].text = leading + replacement + trailing
                proposal[local].confidence = matches[0].confidence
                changed = changed || normalized(proposal[local].text) != normalized(word.text)
            }
            let proposedText = normalized(proposal.map(\.text).joined())
            let corroborated = original[first].alternatives.contains { normalized($0) == proposedText }
            if !changed || corroborated {
                for local in proposal.indices { output[first + local] = proposal[local] }
            }
            first = end
        }
        return output
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
