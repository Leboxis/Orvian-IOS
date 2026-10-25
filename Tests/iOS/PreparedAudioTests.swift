import AVFoundation
import Speech
import Testing
@testable import Orvian

private final class PreparedAudioFixtureBundle: NSObject {}

struct PreparedAudioTests {
    @Test(arguments: ["mpg", "mkv"], [16_000, 48_000])
    func decodesWholeLocalAudioAndSeeksAfterEOF(_ suffix: String, _ rate: Int) async throws {
        let url = try #require(Bundle(for: PreparedAudioFixtureBundle.self)
            .url(forResource: "prepared-audio", withExtension: suffix))
        let cancellation = try PreparedAudioCancellation()
        let decoder = try PreparedAudioDecoder(url: url, sampleRate: rate, channels: 1, cancellation: cancellation)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: true))
        do {
            var frames = 0
            var previousEnd: CMTime?
            while let chunk = try await decoder.read() {
                let input = try #require(try chunk.input(format: format, range: nil))
                let start = try #require(input.bufferStartTime)
                if let previousEnd { #expect(CMTimeCompare(start, previousEnd) >= 0) }
                #expect(chunk.sampleRate == rate)
                #expect(chunk.channelCount == 1)
                #expect(chunk.samples.count == chunk.frameCount)
                #expect(chunk.samples.allSatisfy(\.isFinite))
                previousEnd = CMTimeAdd(start, CMTime(value: Int64(chunk.frameCount), timescale: CMTimeScale(rate)))
                frames += chunk.frameCount
            }
            // MPEG has several audio frames per PES: missing intermediate PTS
            // must be interpolated by the parser, not fail on the second frame.
            let expectedFrames = (suffix == "mkv" ? 3_200 : 3_456) * rate / 16_000
            #expect(frames == expectedFrames)
            let end = try #require(previousEnd)
            #expect(abs(end.seconds - Double(expectedFrames) / Double(rate)) <= 1.0 / Double(rate))
            try await decoder.seek(to: 0)
            let restarted = try #require(try await decoder.read())
            #expect(restarted.startTime < 0.03)
            cancellation.cancel()
            do {
                _ = try await decoder.read()
                Issue.record("Cancelled decoder returned audio")
            } catch is CancellationError {
                // The native cancellation status maps to CancellationError.
            }
            await decoder.close()
        } catch {
            await decoder.close()
            throw error
        }
    }

    @Test func preservesAudioDelayRelativeToVideo() async throws {
        let url = try #require(Bundle(for: PreparedAudioFixtureBundle.self)
            .url(forResource: "prepared-delay", withExtension: "mkv"))
        let cancellation = try PreparedAudioCancellation()
        let decoder = try PreparedAudioDecoder(url: url, sampleRate: 16_000, channels: 1, cancellation: cancellation)
        do {
            let first = try #require(try await decoder.read())
            // Video begins at 0, audio at +2 s. Audio must not be rebased to 0.
            #expect(abs(first.startTime - 2) < 0.002)
            await decoder.close()
        } catch {
            await decoder.close()
            throw error
        }
    }

    @Test func keepsDelayAndTrimsSeekWithoutRebasing() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16_000, channels: 2, interleaved: false))
        let chunk = PreparedAudioChunk(samples: [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4],
                                       frameCount: 4, sampleRate: 16_000, channelCount: 2, startTime: 2)
        let complete = try #require(try chunk.input(format: format, range: nil))
        #expect(complete.bufferStartTime?.seconds == 2)
        #expect(complete.buffer.frameLength == 4)
        let range = CMTimeRange(start: CMTime(value: 32_001, timescale: 16_000),
                                duration: CMTime(value: 2, timescale: 16_000))
        let trimmed = try #require(try chunk.input(format: format, range: range))
        #expect(abs((trimmed.bufferStartTime?.seconds ?? 0) - range.start.seconds) < 1e-8)
        #expect(trimmed.buffer.frameLength == 2)
        let channels = try #require(trimmed.buffer.floatChannelData)
        #expect(abs(channels[0][0] - 0.2) < 1e-6)
        #expect(abs(channels[1][1] + 0.3) < 1e-6)
        let gap = CMTimeRange(start: CMTime(seconds: 5, preferredTimescale: 16_000), duration: CMTime(value: 1, timescale: 1))
        #expect(try chunk.input(format: format, range: gap) == nil)
    }

    @Test(arguments: [16_000, 44_100, 48_000, 96_000])
    func inputTimestampsRemainExactlyContiguous(_ rate: Int) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: true))
        let origin = 5.001
        var end: CMTime?
        for index in 0..<1000 {
            let chunk = PreparedAudioChunk(samples: Array(repeating: 0.1, count: 17), frameCount: 17,
                sampleRate: rate, channelCount: 1, startTime: origin + Double(index * 17) / Double(rate),
                segmentStartTime: origin, frameOffset: Int64(index * 17))
            let input = try #require(try chunk.input(format: format, range: nil))
            let start = try #require(input.bufferStartTime)
            if let end { #expect(CMTimeCompare(start, end) == 0) }
            #expect(abs(start.seconds - chunk.startTime) <= 1e-9)
            end = CMTimeAdd(start, CMTime(value: 17, timescale: CMTimeScale(rate)))
        }
    }

    @Test func speechDiagnosticNamesUseSDKConstantsRatherThanGuessedNumbers() {
        let cases: [(SFSpeechError.Code, String)] = [
            (.audioDisordered, "audioDisordered"),
            (.unexpectedAudioFormat, "unexpectedAudioFormat"),
            (.insufficientResources, "insufficientResources"),
            (.moduleOutputFailed, "moduleOutputFailed")
        ]
        for (code, name) in cases {
            let error = NSError(domain: SFSpeechErrorDomain, code: code.rawValue, userInfo: [
                NSLocalizedDescriptionKey: "https://private.example/movie.mkv?token=SECRET"
            ])
            let message = PreparedSubtitleStage.transcription.failureMessage(for: error)
            #expect(message.contains("[\(name)]"))
            #expect(!message.contains("SECRET"))
        }
    }

    @Test func rejectsMalformedChunksAndNonLocalSources() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let malformed = PreparedAudioChunk(samples: [], frameCount: 4, sampleRate: 16_000, channelCount: 1, startTime: 0)
        #expect(throws: PreparedSubtitleError.self) { try malformed.input(format: format, range: nil) }
        let cancellation = try PreparedAudioCancellation()
        #expect(throws: PreparedSubtitleError.self) {
            try PreparedAudioDecoder(url: URL(string: "https://example.com/video.mkv")!,
                                     sampleRate: 16_000, channels: 1, cancellation: cancellation)
        }
    }
}
