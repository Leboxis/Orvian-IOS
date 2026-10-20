#if DEBUG || ORVIAN_SPEECH_PROBE
import AVFoundation
import MediaToolbox

struct SpeechProbePacket {
    let format: AudioStreamBasicDescription
    let frames: AVAudioFrameCount
    let firstBytes: Int
    let secondBytes: Int
    let timeRange: CMTimeRange
    let startsStream: Bool
    let endsStream: Bool
}

/// Uniquement utilisé par les callbacks séquentiels du même tap.
private final class SpeechTapContext {
    let mailbox: SpeechProbeMailbox<SpeechProbePacket>
    var format = AudioStreamBasicDescription()
    init(mailbox: SpeechProbeMailbox<SpeechProbePacket>) { self.mailbox = mailbox }
}

@MainActor
final class PlayerSpeechAudioTap {
    let mailbox = SpeechProbeMailbox<SpeechProbePacket>()
    private weak var item: AVPlayerItem?
    private let previousMix: AVAudioMix?
    private var installedMix: AVAudioMix?

    init(item: AVPlayerItem, track: AVAssetTrack) throws {
        self.item = item
        previousMix = item.audioMix
        // Le prototype ne remplace jamais les paramètres d'un mix existant.
        guard previousMix == nil else { throw SpeechProbeError.existingMix }
        let context = SpeechTapContext(mailbox: mailbox)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(context).toOpaque(),
            init: { _, info, storage in
                guard let info else { return }
                storage.pointee = Unmanaged<SpeechTapContext>.fromOpaque(info).retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<SpeechTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<SpeechTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.format = format.pointee
            },
            unprepare: nil,
            process: { tap, requested, _, audio, framesOut, flagsOut in
                framesOut.pointee = 0
                flagsOut.pointee = 0
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, requested, audio, flagsOut, &range, framesOut)
                let context = Unmanaged<SpeechTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                // Toujours servir le son, même après arrêt ou saturation de la branche Speech.
                guard status == noErr else { context.mailbox.fail(.sourceAudio); return }
                guard !context.mailbox.isClosed else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(audio)
                let format = context.format
                guard format.mFormatID == kAudioFormatLinearPCM,
                      (1...2).contains(format.mChannelsPerFrame),
                      format.mBytesPerFrame > 0,
                      buffers.count > 0, buffers.count <= 2,
                      framesOut.pointee >= 0, framesOut.pointee <= Int(UInt32.max) else {
                    context.mailbox.fail(.format)
                    return
                }
                let frames = AVAudioFrameCount(framesOut.pointee)
                let starts = flagsOut.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0
                let ends = flagsOut.pointee & kMTAudioProcessingTapFlag_EndOfStream != 0
                guard frames > 0 || starts || ends else { return }
                let expectedBytes = Int(frames) * Int(format.mBytesPerFrame)
                guard buffers.allSatisfy({ Int($0.mDataByteSize) >= expectedBytes && (expectedBytes == 0 || $0.mData != nil) }) else {
                    context.mailbox.fail(.format)
                    return
                }
                let first = UnsafeRawBufferPointer(start: buffers[0].mData, count: expectedBytes)
                let second = UnsafeRawBufferPointer(start: buffers.count == 2 ? buffers[1].mData : nil,
                                                    count: buffers.count == 2 ? expectedBytes : 0)
                context.mailbox.push(
                    SpeechProbePacket(format: format, frames: frames, firstBytes: first.count,
                                      secondBytes: second.count, timeRange: range, startsStream: starts, endsStream: ends),
                    first: first, second: second
                )
            }
        )
        var tap: MTAudioProcessingTap?
        let status = withExtendedLifetime(context) {
            MTAudioProcessingTapCreate(nil, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        }
        guard status == noErr, let tap else { throw SpeechProbeError.tapCreation }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        // AVPlayerItem copie le mix ; conserver la copie réellement installée pour le démontage.
        item.audioMix = mix
        guard let appliedMix = item.audioMix else { throw SpeechProbeError.tapCreation }
        installedMix = appliedMix
    }

    func detach() {
        mailbox.close()
        if let item, item.audioMix === installedMix { item.audioMix = previousMix }
    }
}
#endif
