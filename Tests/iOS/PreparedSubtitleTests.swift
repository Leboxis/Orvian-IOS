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
        let consumer = Task { () -> (Double?, Int, Float?) in
            var firstTime: Double?
            var frames = 0
            var firstValue: Float?
            for await input in stream {
                if firstTime == nil { firstTime = input.bufferStartTime?.seconds }
                if firstValue == nil { firstValue = input.buffer.floatChannelData?[0][0] }
                frames += Int(input.buffer.frameLength)
            }
            return (firstTime, frames, firstValue)
        }
        do {
            try await PreparedSubtitleAnalyzer.shared.pump(reader: reader, output: output, format: format,
                duration: 6, continuation: continuation, progress: { _ in })
            continuation.finish()
            let result = await consumer.value
            XCTAssertEqual(try XCTUnwrap(result.0), 5, accuracy: 0.001)
            XCTAssertEqual(result.1, 16000)
            XCTAssertEqual(try XCTUnwrap(result.2), 0.1, accuracy: 0.001)
        } catch {
            continuation.finish()
            consumer.cancel()
            _ = await consumer.value
            throw error
        }
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
