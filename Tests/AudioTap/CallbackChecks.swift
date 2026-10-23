import AVFoundation
import MediaToolbox

// Le harnais compile les vrais callbacks sans Speech, SwiftUI ni modèle téléchargé.
enum SpeechProbeError: Error { case existingMix, tapCreation }

@main
struct CallbackChecks {
    @MainActor
    static func main() async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { fatalError("Missing fixture track") }
        let item = AVPlayerItem(asset: composition)
        let owner = try PlayerSpeechAudioTap(item: item, track: track)
        guard let tap = item.audioMix?.inputParameters.first?.audioTapProcessor,
              let prepare = PlayerSpeechAudioTap.makeCallbacks(clientInfo: nil).prepare else {
            fatalError("Missing audio tap callback")
        }
        // Le thread appelant est volontairement différent de MainActor, comme
        // lors de la lecture. Les contrôles d'exécuteur doivent rester actifs.
        await Task.detached {
            var format = AudioStreamBasicDescription(mSampleRate: 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            for _ in 0..<100 { prepare(tap, 1024, &format) }
        }.value
        precondition(owner.diagnostics().contains("prepares=100"))
        precondition(owner.detach())
        print("Audio tap callbacks ran outside MainActor without an executor assertion")
    }
}
