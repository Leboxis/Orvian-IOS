import AVFoundation
import Speech
import Testing
@testable import Orvian

private final class PreparedAudioFixtureBundle: NSObject {}

struct PreparedAudioTests {
    @Test(arguments: ["mpg", "mkv"])
    func decodesWholeLocalAudioAndSeeksAfterEOF(_ suffix: String) async throws {
        let url = try #require(Bundle(for: PreparedAudioFixtureBundle.self)
            .url(forResource: "prepared-audio", withExtension: suffix))
        let cancellation = try PreparedAudioCancellation()
        let decoder = try PreparedAudioDecoder(url: url, sampleRate: 16_000, channels: 1, cancellation: cancellation)
        do {
            var frames = 0
            var previousEnd = 0.0
            while let chunk = try await decoder.read() {
                #expect(chunk.startTime >= previousEnd - 0.002)
                #expect(chunk.sampleRate == 16_000)
                #expect(chunk.channelCount == 1)
                #expect(chunk.samples.count == chunk.frameCount)
                #expect(chunk.samples.allSatisfy(\.isFinite))
                previousEnd = chunk.startTime + Double(chunk.frameCount) / 16_000
                frames += chunk.frameCount
            }
            // MPEG has several audio frames per PES: missing intermediate PTS
            // must be interpolated by the parser, not fail on the second frame.
            let expectedFrames = suffix == "mkv" ? 3_200 : 3_456
            #expect(frames == expectedFrames)
            #expect(abs(previousEnd - Double(expectedFrames) / 16_000) <= 1.0 / 16_000)
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
