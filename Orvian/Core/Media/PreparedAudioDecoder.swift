import Foundation
import AVFoundation
import Speech
import OrvianAudioDecoder

/// Only the atomic cancellation token is shared with a task cancellation handler.
final class PreparedAudioCancellation: @unchecked Sendable {
    let handle: OpaquePointer

    init() throws {
        guard let handle = OADCancellationCreate() else { throw PreparedSubtitleError.tooLarge }
        self.handle = handle
    }

    func cancel() { OADCancellationCancel(handle) }
    deinit { OADCancellationRelease(handle) }
}

struct PreparedAudioChunk: Sendable {
    let samples: [Float]
    let frameCount: Int
    let sampleRate: Int
    let channelCount: Int
    let startTime: Double

    /// Trim seeks on the source timeline, then change only the PCM representation.
    func input(format: AVAudioFormat, range: CMTimeRange?) throws -> AnalyzerInput? {
        guard (1...1_000_000).contains(frameCount), (1...8).contains(channelCount),
              (16_000...192_000).contains(sampleRate), samples.count == frameCount * channelCount,
              startTime.isFinite, startTime >= 0,
              format.sampleRate == Double(sampleRate), Int(format.channelCount) == channelCount else {
            throw PreparedSubtitleError.timing
        }
        var lower = 0
        var upper = frameCount
        if let range {
            guard range.start.seconds.isFinite, range.end.seconds.isFinite,
                  range.start.seconds >= 0, range.end.seconds > range.start.seconds else {
                throw PreparedSubtitleError.timing
            }
            // Clamp before converting to Int: a distant range may exceed Int.max.
            lower = Int(min(Double(frameCount), max(0, ceil((range.start.seconds - startTime) * Double(sampleRate) - 1e-7))))
            upper = Int(min(Double(frameCount), max(0, ceil((range.end.seconds - startTime) * Double(sampleRate) - 1e-7))))
        }
        guard upper > lower else { return nil }
        let frames = AVAudioFrameCount(upper - lower)
        guard let nativeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                               channels: AVAudioChannelCount(channelCount), interleaved: true),
              let native = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: frames),
              let destination = native.floatChannelData?[0] else { throw PreparedSubtitleError.source }
        native.frameLength = frames
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress! + lower * channelCount, count: Int(frames) * channelCount)
        }
        let buffer: AVAudioPCMBuffer
        if nativeFormat == format {
            buffer = native
        } else {
            guard let converter = AVAudioConverter(from: nativeFormat, to: format),
                  let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw PreparedSubtitleError.source
            }
            try converter.convert(to: converted, from: native)
            guard converted.frameLength == frames else { throw PreparedSubtitleError.timing }
            buffer = converted
        }
        let time = CMTime(seconds: startTime + Double(lower) / Double(sampleRate), preferredTimescale: 1_000_000_000)
        return AnalyzerInput(buffer: buffer, bufferStartTime: time)
    }
}

/// Serial ownership of a local-file audio decoder. No video frames, audio output,
/// microphone or remote URL is involved; the native framework hides FFmpeg symbols.
actor PreparedAudioDecoder {
    nonisolated let duration: Double
    private var handle: OpaquePointer?

    init(url: URL, sampleRate: Int, channels: Int, cancellation: PreparedAudioCancellation) throws {
        guard url.isFileURL, (16_000...192_000).contains(sampleRate), (1...8).contains(channels) else {
            throw PreparedSubtitleError.source
        }
        var status = OADStatusOK
        let decoder = url.path.withCString {
            OADOpen($0, Int32(sampleRate), Int32(channels), cancellation.handle, &status)
        }
        guard let decoder else { throw Self.error(for: status) }
        handle = decoder
        let duration = OADDuration(decoder)
        self.duration = duration.isFinite && duration > 0 ? duration : 0
    }

    func read() throws -> PreparedAudioChunk? {
        try Task.checkCancellation()
        guard let handle else { throw PreparedSubtitleError.source }
        var block = OADAudioBlock()
        let status = OADRead(handle, &block)
        if status == OADStatusEnd { return nil }
        guard status == OADStatusOK else { throw Self.error(for: status) }
        guard let samples = block.samples,
              (1...1_000_000).contains(block.frameCount),
              (1...8).contains(block.channelCount),
              (16_000...192_000).contains(block.sampleRate),
              block.startTime.isFinite, block.startTime >= 0 else { throw PreparedSubtitleError.timing }
        let count = Int(block.frameCount) * Int(block.channelCount)
        // Native storage is borrowed until the next read. Copy before crossing actors.
        let copied = Array(UnsafeBufferPointer(start: samples, count: count))
        try Task.checkCancellation()
        return PreparedAudioChunk(samples: copied, frameCount: Int(block.frameCount),
                                  sampleRate: Int(block.sampleRate), channelCount: Int(block.channelCount),
                                  startTime: block.startTime)
    }

    func seek(to seconds: Double) throws {
        guard let handle, seconds.isFinite, seconds >= 0 else { throw PreparedSubtitleError.timing }
        let status = OADSeek(handle, seconds)
        guard status == OADStatusOK else { throw Self.error(for: status) }
    }

    func close() {
        if let handle { OADClose(handle) }
        handle = nil
    }

    deinit {
        if let handle { OADClose(handle) }
    }

    private static func error(for status: OADStatus) -> Error {
        switch status {
        case OADStatusCancelled: CancellationError()
        case OADStatusNoAudio: PreparedSubtitleError.noAudio
        case OADStatusMultipleAudio: PreparedSubtitleError.multipleTracks
        case OADStatusUnsupportedAudio: PreparedSubtitleError.unsupportedMedia
        case OADStatusInvalidTiming: PreparedSubtitleError.timing
        case OADStatusTooLarge, OADStatusOutOfMemory: PreparedSubtitleError.tooLarge
        default: PreparedSubtitleError.source
        }
    }
}
