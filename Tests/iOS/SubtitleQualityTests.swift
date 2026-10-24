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

    func testDisplayDurationStartsWhenLateTextBecomesAvailable() {
        var timeline = SubtitleCueTimeline()
        timeline.maximumAge = 3
        var delayed = cue("An original-language caption", start: 10)
        delayed.displayStart = 14
        timeline.upsert(delayed)
        XCTAssertNotNil(timeline.cue(at: 15), "A three-second setting must not hide a late caption immediately")
        XCTAssertNil(timeline.cue(at: 18), "The caption must still disappear after its configured lifetime")
    }

    func testStoredNumericPreferencesAreBounded() {
        XCTAssertEqual(SubtitleSettings.fontSize(.nan), 17)
        XCTAssertEqual(SubtitleSettings.fontSize(100), 28)
        XCTAssertEqual(SubtitleSettings.backgroundOpacity(-1), 0.6)
        XCTAssertEqual(SubtitleSettings.backgroundOpacity(.infinity), 0.72)
        XCTAssertEqual(SubtitleSettings.displayDuration(0), 3)
        XCTAssertEqual(SubtitleSettings.displayDuration(.nan), 6)
    }

    @MainActor
    func testConfiguredDurationAppliesToBothLanguageTimelines() {
        let probe = VideoSpeechProbe()
        probe.setSourceLanguage(.french)
        probe.setMode(.french, player: nil, start: {}, stopTest: {})
        probe.setDisplayDuration(3)
        probe.publishTranscript(text: "Bonjour.", start: 0, isFinal: true)
        probe.refreshCues(at: 4)
        XCTAssertNil(probe.englishCue)
        XCTAssertNil(probe.displayedCue)
        probe.setDisplayDuration(10)
        probe.refreshCues(at: 4)
        XCTAssertEqual(probe.displayedCue?.text, "Bonjour.")
        XCTAssertEqual(probe.englishCue?.text, "Bonjour.")
        probe.stop()
    }

    @MainActor
    func testFrenchModeNeverShowsOriginalAndLanguageChangeClearsOldState() {
        let probe = VideoSpeechProbe()
        probe.setMode(.french, player: nil, start: {}, stopTest: {})
        probe.publishTranscript(text: "An unfinished English fragment", start: 0, isFinal: false)
        probe.refreshCues(at: 0)
        XCTAssertNotNil(probe.englishCue)
        XCTAssertNil(probe.displayedCue, "French mode must not fall back to English")
        XCTAssertNotNil(probe.translationConfiguration)
        probe.setSourceLanguage(.french)
        XCTAssertNil(probe.translationConfiguration, "French audio needs transcription only")
        XCTAssertNil(probe.displayedCue)
        probe.publishTranscript(text: "Bonjour, tout le monde.", start: 0, isFinal: true)
        probe.refreshCues(at: 0)
        XCTAssertEqual(probe.displayedCue?.text, "Bonjour, tout le monde.")
        probe.setSourceLanguage(.spanish)
        XCTAssertNotNil(probe.translationConfiguration)
        XCTAssertEqual(probe.sourceLanguage.localeIdentifier, "es-ES")
        XCTAssertNil(probe.displayedCue)
        probe.stop()
    }
}
