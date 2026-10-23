import Foundation
import CoreML
import FluidAudio

@main struct UltraSmoke {
    static func main() async throws {
        AppLogger.minimumLevel = .fault
        AppLogger.mirrorsToConsole = false
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let models = try await AsrModels.downloadAndLoad(configuration: configuration, version: .ultra)
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
        do {
            var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(URL(fileURLWithPath: CommandLine.arguments[1]), decoderState: &state, language: .english)
            let text = result.text.lowercased()
            guard result.duration > 30, text.contains("orchard"), text.contains("lantern"),
                  text.contains("complete"), let timings = result.tokenTimings, !timings.isEmpty,
                  timings.last!.startTime > 30,
                  timings.allSatisfy({ $0.startTime.isFinite && $0.startTime >= 0 && $0.endTime > $0.startTime }),
                  timings.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines) == result.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw NSError(domain: "UltraSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ultra long-form transcription or source timing validation failed"])
            }
            print("Ultra long-form inference passed: \(result.duration) seconds, \(timings.count) timed tokens")
            await manager.cleanup()
        } catch {
            await manager.cleanup()
            throw error
        }
    }
}
