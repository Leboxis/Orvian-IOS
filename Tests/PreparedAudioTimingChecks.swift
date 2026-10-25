import Foundation

@main struct PreparedAudioTimingChecks {
    static func main() throws {
        for rate in [44_100, 48_000, 16_000, 22_050, 32_000, 88_200, 96_000, 192_000] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: true)!
            let frames = 17
            let origin = 5.001
            var previousEnd: CMTime?
            for index in 0..<100 {
                let chunk = PreparedAudioChunk(samples: Array(repeating: 0.1, count: frames), frameCount: frames,
                    sampleRate: rate, channelCount: 1, startTime: origin + Double(index * frames) / Double(rate),
                    segmentStartTime: origin, frameOffset: Int64(index * frames))
                let input = try chunk.input(format: format, range: nil)!
                let start = input.bufferStartTime!
                if let previousEnd {
                    precondition(CMTimeCompare(start, previousEnd) >= 0,
                        "audioDisordered: next start \(start.value)/\(start.timescale) precedes previous end \(previousEnd.value)/\(previousEnd.timescale) at \(rate)Hz")
                }
                precondition(abs(start.seconds - chunk.startTime) < 1.0 / Double(rate), "Source offset lost")
                previousEnd = CMTimeAdd(start, CMTime(value: Int64(frames), timescale: Int32(rate)))
            }
        }
        let rate = 48_000
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: true)!
        let gap = PreparedAudioChunk(samples: Array(repeating: 0.1, count: 8), frameCount: 8,
            sampleRate: rate, channelCount: 1, startTime: 7.125, segmentStartTime: 7.125)
        let gapInput = try gap.input(format: format, range: nil)!
        precondition(abs(gapInput.bufferStartTime!.seconds - 7.125) < 1e-9, "A real silence was collapsed")
        let range = CMTimeRange(start: CMTime(value: 240_002, timescale: 48_000), duration: CMTime(value: 4, timescale: 48_000))
        let chunk = PreparedAudioChunk(samples: Array(repeating: 0.1, count: 8), frameCount: 8,
            sampleRate: rate, channelCount: 1, startTime: 5, segmentStartTime: 5)
        let trimmed = try chunk.input(format: format, range: range)!
        precondition(trimmed.buffer.frameLength == 4)
        precondition(CMTimeCompare(trimmed.bufferStartTime!, range.start) == 0, "Seek trim changed the original PTS")
        let preroll = PreparedAudioChunk(samples: Array(repeating: 0.1, count: 8), frameCount: 8,
            sampleRate: rate, channelCount: 1, startTime: 0, segmentStartTime: -0.01, frameOffset: 480)
        let zero = try preroll.input(format: format, range: nil)!
        precondition(zero.bufferStartTime!.seconds == 0, "Preroll offset was lost")
        print("Prepared audio input chronology, gaps, source delay, seek trim and preroll checks passed")
    }
}
