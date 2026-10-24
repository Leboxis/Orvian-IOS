import XCTest
import AVFoundation
import Speech
@testable import Orvian

final class PreparedSubtitleTests: XCTestCase {
    private func file() throws -> DriveFile {
        try JSONDecoder().decode(DriveFile.self, from: Data(#"{"id":42,"name":"video.mov","type":"file","size":100,"last_modified_at":10}"#.utf8))
    }
    private func key(source: SubtitleSourceLanguage = .english, credential: String = "accountA") throws -> PreparedSubtitleKey {
        PreparedSubtitleKey(credential: credential, driveID: 1, file: try file(), source: source)
    }
    private func document() throws -> PreparedSubtitles {
        PreparedSubtitles(key: try key(), createdAt: Date(), cues: [
            .init(start: 2, end: 4, original: "Hello.", french: "Bonjour."),
            .init(start: 6, end: 8, original: "Goodbye.", french: "Au revoir.")
        ])
    }
    private func contextFixture() -> [PreparedSubtitle] {
        [(0.0, 1.0, "Too old."), (1, 3, "Boundary."), (3, 4, "Near."),
         (8, 9, "Previous."), (11, 12, "Current."), (30, 31, "After silence.")].map {
            PreparedSubtitle(start: $0.0, end: $0.1, original: $0.2, french: "")
        }
    }
    private func tagged(_ text: String, range: CMTimeRange) -> AttributedString {
        var result = AttributedString(text)
        result[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = range
        return result
    }
    func testFollowingContextUsesWholeSentenceAndSelectsMiddleCaption() throws {
        let cues = [PreparedSubtitle(start: 1, end: 2, original: "Before.", french: ""),
                    .init(start: 3, end: 4, original: "Current.", french: ""),
                    .init(start: 5, end: 10, original: "Following boundary sentence.", french: ""),
                    .init(start: 10, end: 11, original: "Too far.", french: "")]
        let context = PreparedSubtitleContext(cues: cues, index: 1)
        XCTAssertEqual(context.currentIndex, 1)
        XCTAssertEqual(String(context.text.characters), "Before. Current. Following boundary sentence.")
        var response = tagged("Avant. ", range: context.ranges[0])
        response += tagged("Actuelle. ", range: context.currentRange)
        response += tagged("Après.", range: context.ranges[2])
        XCTAssertEqual(try context.currentTranslation(from: response), "Actuelle.")
        XCTAssertEqual(context.currentRange.start.seconds, 3)
        XCTAssertEqual(context.currentRange.end.seconds, 4)
    }
    func testLinksPreserveCurrentCaptionWithoutSpeechAttributes() throws {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        var response = AttributedString()
        for (index, value) in ["Proche. ", "Précédente. ", "Actuelle."].enumerated() {
            var fragment = AttributedString(value)
            fragment.link = context.identifiers[index]
            response += fragment
        }
        XCTAssertEqual(try context.currentTranslation(from: response), "Actuelle.")
        var conflicting = tagged("Mauvaise identité.", range: context.ranges[0])
        conflicting.link = context.identifiers[context.currentIndex]
        XCTAssertThrowsError(try context.currentTranslation(from: conflicting))
    }
    @MainActor func testCompactContextRetryPrecedesIsolation() async throws {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        var attempts = 0
        let result = try await context.translateCurrent(contextual: { input in
            attempts += 1
            if attempts == 1 { return nil }
            XCTAssertEqual(String(input.characters), "Previous. Current.")
            XCTAssertTrue(input.runs.allSatisfy { $0[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] == nil })
            var before = AttributedString("Précédente. ")
            before.link = context.identifiers[context.currentIndex - 1]
            var current = AttributedString("Actuelle.")
            current.link = context.identifiers[context.currentIndex]
            return before + current
        }, isolated: { _ in XCTFail("Preserved compact context must not use isolation"); return "" })
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(result.usedContext)
        XCTAssertTrue(result.reducedContext)
        XCTAssertEqual(result.text, "Actuelle.")
    }
    func testUncertaintyRereadBudgetsAndMissingConfidence() {
        XCTAssertNil(PreparedSpeechRefinement.confidence(.nan))
        XCTAssertNil(PreparedSpeechRefinement.confidence(2))
        XCTAssertTrue(PreparedSpeechRefinement.windows(for: [.init(start: 10, end: 11, text: "Unknown")], duration: 30).isEmpty)
        let many: [PreparedSpeechSpan] = (0..<100).map { index in
            let start = Double(index * 40 + 10)
            return PreparedSpeechSpan(start: start, end: start + 1, text: "Word", confidence: 0.3)
        }
        let windows = PreparedSpeechRefinement.windows(for: many, duration: 5000)
        XCTAssertLessThanOrEqual(windows.count, 12)
        XCTAssertLessThanOrEqual(windows.reduce(0) { $0 + $1.duration.seconds }, 180)
        XCTAssertTrue(windows.allSatisfy { $0.duration.seconds <= 30 })
        XCTAssertEqual(windows[0].start.seconds, 2)
        XCTAssertEqual(windows[0].end.seconds, 15)
    }
    func testUncertainWordRequiresCorroboratedAlternativeAndPreservesTimes() throws {
        let original = [PreparedSpeechSpan(start: 5, end: 5.5, text: "The ", beginsResult: true, confidence: 0.95,
                                          alternatives: ["The ship."]),
                        .init(start: 5.5, end: 6, text: "sheep.", confidence: 0.3)]
        let reread = [PreparedSpeechSpan(start: 5, end: 5.5, text: "A ", confidence: 1),
                      .init(start: 5.5, end: 6, text: "ship.", confidence: 0.9)]
        let merged = PreparedSpeechRefinement.merge(original: original, reread: reread)
        XCTAssertEqual(merged.map(\.text), ["The ", "ship."])
        XCTAssertEqual(merged.map(\.start), original.map(\.start))
        XCTAssertEqual(merged.map(\.end), original.map(\.end))
        XCTAssertFalse(try PreparedSentenceBuilder.make(merged, source: .english)[0].needsReview == true)
        var unsupported = original
        unsupported[0].alternatives = ["The shop."]
        XCTAssertEqual(PreparedSpeechRefinement.merge(original: unsupported, reread: reread).map(\.text), original.map(\.text))
        XCTAssertTrue(try PreparedSentenceBuilder.make(unsupported, source: .english)[0].needsReview == true)
        var wrongTime = reread
        wrongTime[1] = .init(start: 8, end: 9, text: "ship.", confidence: 0.99)
        XCTAssertEqual(PreparedSpeechRefinement.merge(original: original, reread: wrongTime).map(\.text), original.map(\.text))
    }
    func testAppleInvalidatesThirdPartyPreparedCache() throws {
        let doc = try document()
        for version in [1, 2, 3, 4, 5, 6] {
            var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
            var key = try XCTUnwrap(encoded["key"] as? [String: Any])
            key["version"] = version
            encoded["key"] = key
            let old = try JSONDecoder().decode(PreparedSubtitles.self, from: JSONSerialization.data(withJSONObject: encoded))
            XCTAssertFalse(old.isValid)
        }
    }
    func testRetiredModelCleanupPreservesOtherApplicationData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("FluidAudio/Models/parakeet-ultra", isDirectory: true)
        let preserved = root.appendingPathComponent("OtherModels", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
        TemporaryFileSweeper.removeLegacySubtitleModel(applicationSupport: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        TemporaryFileSweeper.removeLegacySubtitleModel(applicationSupport: root)
    }
    func testContextWindowUsesMediaSecondsAndNeverFutureText() {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        XCTAssertEqual(String(context.text.characters), "Near. Previous. Current.")
        XCTAssertEqual(context.ranges.count, 3)
        XCTAssertTrue(context.hasContext)
        XCTAssertEqual(context.currentRange.start.seconds, 11)
        XCTAssertEqual(context.currentRange.end.seconds, 12)
    }
    func testContextKeepsBoundarySentenceWholeAndStopsAcrossSilence() {
        var cues = contextFixture()
        cues[1].end = 3.1
        let overlapping = PreparedSubtitleContext(cues: cues, index: 4)
        XCTAssertEqual(String(overlapping.text.characters), "Boundary. Near. Previous. Current.")
        let silent = PreparedSubtitleContext(cues: cues, index: 5)
        XCTAssertEqual(String(silent.text.characters), "After silence.")
        XCTAssertFalse(silent.hasContext)
    }
    func testContextExtractionDoesNotRepeatEarlierTranslations() throws {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        var translated = tagged("Proche. ", range: context.ranges[0])
        translated += tagged("Précédente. ", range: context.ranges[1])
        translated += tagged("Actuelle", range: context.currentRange)
        translated += AttributedString(" ")
        translated += tagged("complète.", range: context.currentRange)
        XCTAssertEqual(try context.currentTranslation(from: translated), "Actuelle complète.")
    }
    func testMissingOrAmbiguousContextAlignmentCannotBeSavedAsCurrentCaption() {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        XCTAssertThrowsError(try context.currentTranslation(from: nil))
        XCTAssertThrowsError(try context.currentTranslation(from: AttributedString("Sans repères.")))
        XCTAssertThrowsError(try context.currentTranslation(from: tagged("Partielle.", range: context.currentRange)))
        var interleaved = tagged("Début", range: context.currentRange)
        interleaved += tagged("Contexte", range: context.ranges[0])
        interleaved += tagged("Autre", range: context.ranges[1])
        interleaved += tagged("Fin", range: context.currentRange)
        XCTAssertThrowsError(try context.currentTranslation(from: interleaved))
    }
    @MainActor func testLostContextAttributesRetryOnlyCurrentSentence() async throws {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        let ambiguous = tagged("Contexte et phrase fusionnés", range: CMTimeRange(start: .zero, duration: CMTime(seconds: 12, preferredTimescale: 600)))
        let outputs: [AttributedString?] = [nil, AttributedString("Tout le contexte traduit."), ambiguous]
        for output in outputs {
            var isolatedCalls = 0
            let result = try await context.translateCurrent(contextual: { input in
                XCTAssertTrue(["Near. Previous. Current.", "Previous. Current."].contains(String(input.characters)))
                return output
            }, isolated: { source in
                isolatedCalls += 1
                XCTAssertEqual(source, "Current.")
                return "  Actuelle.  "
            })
            XCTAssertEqual(isolatedCalls, 1)
            XCTAssertEqual(result.text, "Actuelle.")
            XCTAssertFalse(result.usedContext)
        }
    }
    @MainActor func testValidContextKeepsContextualTranslationWithoutRetry() async throws {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        var translated = tagged("Proche. ", range: context.ranges[0])
        translated += tagged("Précédente. ", range: context.ranges[1])
        translated += tagged("Actuelle.", range: context.currentRange)
        let result = try await context.translateCurrent(contextual: { _ in translated }, isolated: { _ in
            XCTFail("Valid context must not trigger isolated translation")
            return ""
        })
        XCTAssertEqual(result.text, "Actuelle.")
        XCTAssertTrue(result.usedContext)
    }
    @MainActor func testContextRetryPreservesCancellationAndRejectsEmptyTranslation() async {
        let context = PreparedSubtitleContext(cues: contextFixture(), index: 4)
        do {
            _ = try await context.translateCurrent(contextual: { _ in throw CancellationError() }, isolated: { _ in
                XCTFail("Cancellation must not retry translation")
                return "Actuelle."
            })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await context.translateCurrent(contextual: { _ in nil }, isolated: { _ in "  " })
            XCTFail("Empty translation must not be saved")
        } catch PreparedSubtitleError.incomplete { } catch { XCTFail("Unexpected error: \(error)") }
    }
    func testOldContextFreeCacheIsInvalidOnContextCapableSystem() throws {
        guard #available(iOS 26.4, *) else { throw XCTSkip("Context requires iOS 26.4") }
        let doc = try document()
        XCTAssertEqual(doc.key.version, 8)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
        var key = try XCTUnwrap(json["key"] as? [String: Any])
        key["version"] = 1
        json["key"] = key
        let old = try JSONDecoder().decode(PreparedSubtitles.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.isValid)
        XCTAssertNotEqual(old.key, doc.key)
    }
    func testExactBoundariesSilenceAndBackwardSeek() throws {
        let doc = try document()
        XCTAssertTrue(doc.isValid)
        XCTAssertNil(doc.cue(at: 1.999, mode: .french))
        XCTAssertEqual(doc.cue(at: 2, mode: .french)?.text, "Bonjour.")
        XCTAssertNil(doc.cue(at: 4, mode: .french))
        XCTAssertNil(doc.cue(at: 5, mode: .french))
        XCTAssertEqual(doc.cue(at: 7, mode: .french)?.text, "Au revoir.")
        XCTAssertEqual(doc.cue(at: 3, mode: .english)?.text, "Hello.")
        XCTAssertNil(doc.cue(at: .nan, mode: .french))
        XCTAssertNil(doc.cue(at: 3, mode: .off))
    }
    func testNeverAcceptPartialOrOverlappingTranslations() throws {
        let key = try key()
        let incomplete = PreparedSubtitles(key: key, createdAt: Date(), cues: [.init(start: 0, end: 1, original: "Hello", french: "")])
        XCTAssertFalse(incomplete.isValid)
        let overlap = PreparedSubtitles(key: key, createdAt: Date(), cues: [
            .init(start: 0, end: 2, original: "One", french: "Un"),
            .init(start: 1, end: 3, original: "Two", french: "Deux")])
        XCTAssertFalse(overlap.isValid)
    }
    func testSentenceTextAndRealAudioTimesArePreserved() throws {
        let spans = [PreparedSpeechSpan(start: 2, end: 2.4, text: "Hello "),
                     PreparedSpeechSpan(start: 2.4, end: 3.1, text: "world."),
                     PreparedSpeechSpan(start: 5, end: 6, text: "Goodbye.", beginsResult: true)]
        let cues = try PreparedSentenceBuilder.make(spans, source: .english)
        XCTAssertEqual(cues.map(\.original), ["Hello world.", "Goodbye."])
        XCTAssertEqual(cues.map(\.start), [2, 5])
        XCTAssertEqual(cues.map(\.end), [3.1, 6])
    }
    func testFinalResultFragmentsKeepTheirWordBoundary() throws {
        let cues = try PreparedSentenceBuilder.make([
            .init(start: 0, end: 1, text: "Hello", beginsResult: true),
            .init(start: 1, end: 2, text: "world.", beginsResult: true)
        ], source: .english)
        XCTAssertEqual(cues.map(\.original), ["Hello world."])
    }
    func testCoarseSpeechTimesMergeWithoutLosingWords() throws {
        let cues = try PreparedSentenceBuilder.make([.init(start: 2, end: 7, text: "Hello world. Goodbye world.")], source: .english)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].original, "Hello world. Goodbye world.")
        XCTAssertEqual(cues[0].start, 2)
        XCTAssertEqual(cues[0].end, 7)
        XCTAssertThrowsError(try PreparedSentenceBuilder.make([.init(start: 2, end: 1, text: "Bad")], source: .english))
    }
    func testCacheIsolationAndAtomicReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreparedSubtitleStore(root: root, currentCredential: { "accountA" })
        let doc = try document()
        try await store.save(doc)
        let loaded = await store.load(doc.key)
        XCTAssertEqual(loaded, doc)
        let foreignKey = try key(credential: "accountB")
        let other = await store.load(foreignKey)
        XCTAssertNil(other)
        let changedSource = await store.load(try key(source: .german))
        XCTAssertNil(changedSource)
        do {
            try await store.save(PreparedSubtitles(key: doc.key, createdAt: Date(), cues: []))
            XCTFail("Incomplete document must not replace a complete cache")
        } catch { }
        let unchanged = await store.load(doc.key)
        XCTAssertEqual(unchanged, doc)
        await store.clear(credential: "accountA")
        let removed = await store.load(doc.key)
        XCTAssertNil(removed)
    }
    func testRealPCMDecodeKeepsTrackOffsetAndAllSamples() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            for index in 0..<16000 { buffer.floatChannelData![0][index] = 0.1 }
            try file.write(from: buffer)
            file.close()
        }
        let source = AVURLAsset(url: url)
        let sourceTracks = try await source.loadTracks(withMediaType: .audio)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 16000)),
                                  of: sourceTrack, at: CMTime(seconds: 5, preferredTimescale: 16000))
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: format.settings)
        reader.add(output)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(4))
        let consumer = Task { () -> (firstAudio: Double?, totalFrames: Int, audibleFrames: Int, end: Double) in
            var firstAudio: Double?
            var frames = 0
            var audibleFrames = 0
            var end = 0.0
            for await input in stream {
                let count = Int(input.buffer.frameLength)
                let start = input.bufferStartTime?.seconds ?? .nan
                if let samples = input.buffer.floatChannelData?[0] {
                    for index in 0..<count where abs(samples[index]) > 0.0001 {
                        if firstAudio == nil { firstAudio = start + Double(index) / format.sampleRate }
                        audibleFrames += 1
                    }
                }
                frames += count
                end = start + Double(count) / format.sampleRate
            }
            return (firstAudio, frames, audibleFrames, end)
        }
        do {
            try await PreparedSubtitleAnalyzer.shared.pump(reader: reader, output: output, format: format,
                duration: 6, continuation: continuation, progress: { _ in })
            continuation.finish()
            let result = await consumer.value
            // AVAssetReader matérialise l'edit vide initial par cinq secondes
            // de PCM silencieux. C'est le premier son, pas le premier buffer,
            // qui doit rester exactement à 5 s sur la timeline vidéo.
            XCTAssertEqual(try XCTUnwrap(result.firstAudio), 5, accuracy: 0.001)
            XCTAssertEqual(result.totalFrames, 96000)
            XCTAssertEqual(result.audibleFrames, 16000)
            XCTAssertEqual(result.end, 6, accuracy: 0.001)

        } catch {
            continuation.finish()
            consumer.cancel()
            _ = await consumer.value
            throw error
        }
    }
    @MainActor func testCancelBeforeSessionStartsAllowsAnotherPreparation() {
        let job = PreparedSubtitleJob()
        job.start(source: .french)
        let firstRun = job.originalRun
        XCTAssertTrue(job.isRunning)
        job.cancel()
        XCTAssertFalse(job.isRunning)
        job.start(source: .french)
        XCTAssertTrue(job.isRunning)
        XCTAssertNotEqual(firstRun, job.originalRun)
        job.cancel()
    }
    @MainActor func testPlaybackUsesFrenchAndRefreshesOnlyOnCueChanges() throws {
        let playback = PreparedSubtitlePlayback()
        playback.install(try document())
        XCTAssertEqual(playback.mode, .french)
        playback.refresh(at: 2)
        XCTAssertEqual(playback.cue?.text, "Bonjour.")
        playback.refresh(at: 4)
        XCTAssertNil(playback.cue)
        playback.setMode(.english, at: 2)
        XCTAssertEqual(playback.cue?.text, "Hello.")
        playback.install(nil)
        XCTAssertFalse(playback.isAvailable)
        XCTAssertNil(playback.cue)
    }
}
