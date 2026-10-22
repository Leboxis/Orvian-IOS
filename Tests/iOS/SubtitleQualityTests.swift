import AVFoundation
import XCTest
@testable import Orvian

final class SubtitleQualityTests: XCTestCase {
    private func cue(_ text: String, start: Double = 0) -> SubtitleCue {
        SubtitleCue(start: start, end: start + 1, text: text, isFinal: true, isTranslated: false)
    }

    func testFragmentsFormOneSentenceAndSilenceFlushesTail() {
        var buffer = SubtitleSentenceBuffer()
        XCTAssertNil(buffer.append(cue("If we leave")))
        let sentence = buffer.append(cue("now, we can make it.", start: 1))
        XCTAssertEqual(sentence?.text, "If we leave now, we can make it.")
        XCTAssertEqual(sentence?.start, 0)
        XCTAssertEqual(sentence?.end, 2)
        XCTAssertNil(buffer.flush())
        XCTAssertNil(buffer.append(cue("A final fragment")))
        XCTAssertEqual(buffer.flush()?.text, "A final fragment")
    }

    func testUnpunctuatedSpeechCannotGrowWithoutBound() {
        var buffer = SubtitleSentenceBuffer()
        var emitted: SubtitleCue?
        for index in 0..<100 {
            if let next = buffer.append(cue("some words", start: Double(index))) { emitted = next }
        }
        XCTAssertNotNil(emitted)
        XCTAssertLessThanOrEqual(emitted!.text.count, 300)
    }

    func testQueueKeepsOrderWithoutReplacingActiveWork() {
        var queue = SubtitleTranslationQueue()
        queue.append(cue("one"))
        let active = queue.popFirst()
        for index in 2...10 { queue.append(cue(String(index))) }
        XCTAssertEqual(active?.text, "one")
        XCTAssertEqual(queue.count, 4)
        XCTAssertEqual(queue.popFirst()?.text, "7")
        XCTAssertEqual(queue.popFirst()?.text, "8")
        queue.clear()
        XCTAssertNil(queue.popFirst())
    }

    @MainActor
    func testFrenchModeNeverShowsOriginalAndLanguageChangeClearsOldState() {
        let probe = VideoSpeechProbe()
        probe.setMode(.french, player: nil, start: {}, stopTest: {})
        let player = AVPlayer()
        probe.publishTranscript(text: "An unfinished English fragment", start: 0, isFinal: false)
        probe.refresh(player: player)
        XCTAssertNotNil(probe.englishCue)
        XCTAssertNil(probe.displayedCue, "French mode must not fall back to English")
        XCTAssertNotNil(probe.translationConfiguration)
        probe.setSourceLanguage(.french)
        XCTAssertNil(probe.translationConfiguration, "French audio needs transcription only")
        XCTAssertNil(probe.displayedCue)
        probe.setSourceLanguage(.spanish)
        XCTAssertNotNil(probe.translationConfiguration)
        XCTAssertEqual(probe.sourceLanguage.localeIdentifier, "es-ES")
        XCTAssertNil(probe.displayedCue)
        probe.stop()
    }
}
