// Timing-only host shims: execute the real PreparedAudioChunk.input on Windows.
// iOS integration tests exercise the same contract with CoreMedia/AVFoundation.
import Foundation

typealias AVAudioFrameCount = UInt32
typealias AVAudioChannelCount = UInt32
typealias CMTimeScale = Int32

struct CMTime {
    let value: Int64
    let timescale: Int64
    init(value: Int64, timescale: Int32) { self.value = value; self.timescale = Int64(timescale) }
    init(value: Int64, exactScale: Int64) { self.value = value; self.timescale = exactScale }
    init(seconds: Double, preferredTimescale: Int32) {
        self.init(value: Int64((seconds * Double(preferredTimescale)).rounded()), timescale: preferredTimescale)
    }
    var seconds: Double { Double(value) / Double(timescale) }
    var isNumeric: Bool { timescale > 0 }
}
func CMTimeCompare(_ lhs: CMTime, _ rhs: CMTime) -> Int32 {
    let left = Decimal(lhs.value) * Decimal(rhs.timescale)
    let right = Decimal(rhs.value) * Decimal(lhs.timescale)
    return left == right ? 0 : (left < right ? -1 : 1)
}
func CMTimeAdd(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
    var a = Int64(lhs.timescale), b = Int64(rhs.timescale)
    while b != 0 { (a, b) = (b, a % b) }
    let scale = Int64(lhs.timescale) / a * Int64(rhs.timescale)
    // Keep endpoints exact in the host reference, even when the old input's
    // nanosecond scale has an LCM larger than CoreMedia's Int32 timescale.
    return CMTime(value: lhs.value * (scale / Int64(lhs.timescale)) + rhs.value * (scale / Int64(rhs.timescale)), exactScale: scale)
}
struct CMTimeRange {
    let start: CMTime
    let duration: CMTime
    var end: CMTime { CMTimeAdd(start, duration) }
}

enum PCMFormat { case pcmFormatFloat32 }
struct AVAudioFormat: Equatable {
    let commonFormat: PCMFormat
    let sampleRate: Double
    let channelCount: UInt32
    let isInterleaved: Bool
    init?(commonFormat: PCMFormat, sampleRate: Double, channels: UInt32, interleaved: Bool) {
        self.commonFormat = commonFormat; self.sampleRate = sampleRate
        channelCount = channels; isInterleaved = interleaved
    }
}
final class AVAudioPCMBuffer {
    let format: AVAudioFormat
    var frameLength: UInt32 = 0
    let storage: UnsafeMutablePointer<Float>
    let planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { UnsafePointer(planes) }
    init?(pcmFormat: AVAudioFormat, frameCapacity: UInt32) {
        format = pcmFormat
        storage = .allocate(capacity: Int(frameCapacity * pcmFormat.channelCount))
        planes = .allocate(capacity: 1)
        planes.initialize(to: storage)
    }
    deinit { planes.deinitialize(count: 1); planes.deallocate(); storage.deallocate() }
}
final class AVAudioConverter {
    init?(from: AVAudioFormat, to: AVAudioFormat) {}
    func convert(to destination: AVAudioPCMBuffer, from source: AVAudioPCMBuffer) throws {
        preconditionFailure("Timing checks must not exercise a simulated PCM conversion")
    }
}
struct AnalyzerInput {
    let buffer: AVAudioPCMBuffer
    let bufferStartTime: CMTime?
}
enum PreparedSubtitleError: Error { case timing, source }
