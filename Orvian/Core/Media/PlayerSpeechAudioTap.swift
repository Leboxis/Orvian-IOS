import AVFoundation
import MediaToolbox
import Synchronization

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
    // Compteurs atomiques : le callback audio ne prend jamais de verrou.
    let callbacks = Atomic<Int>(0)
    let prepared = Atomic<Int>(0)
    let sourceStatus = Atomic<Int32>(0)
    let lastFrames = Atomic<Int>(0)
    let lastFlags = Atomic<UInt32>(0)
    init(mailbox: SpeechProbeMailbox<SpeechProbePacket>) { self.mailbox = mailbox }
}

@MainActor
final class PlayerSpeechAudioTap {
    let mailbox = SpeechProbeMailbox<SpeechProbePacket>()
    private weak var item: AVPlayerItem?
    private let previousMix: AVAudioMix?
    private var installedMix: AVAudioMix?
    private var storedContext: SpeechTapContext?

    init(item: AVPlayerItem, track: AVAssetTrack) throws {
        self.item = item
        previousMix = item.audioMix
        // Le prototype ne remplace jamais les paramètres d'un mix existant.
        guard previousMix == nil else { throw SpeechProbeError.existingMix }
        let context = SpeechTapContext(mailbox: mailbox)
        storedContext = context
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
                context.prepared.wrappingAdd(1, ordering: .relaxed)
            },
            unprepare: nil,
            process: { tap, requested, _, audio, framesOut, flagsOut in
                framesOut.pointee = 0
                flagsOut.pointee = 0
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, requested, audio, flagsOut, &range, framesOut)
                let context = Unmanaged<SpeechTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.callbacks.wrappingAdd(1, ordering: .relaxed)
                context.sourceStatus.store(status, ordering: .relaxed)
                context.lastFrames.store(Int(framesOut.pointee), ordering: .relaxed)
                context.lastFlags.store(flagsOut.pointee, ordering: .relaxed)
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

    @discardableResult
    func detach() -> Bool {
        mailbox.close()
        guard let item, let installedMix, item.audioMix === installedMix else { return false }
        item.audioMix = previousMix
        return true
    }

    /// Photo du tap, lue hors callback : distingue « aucun audio » d'un rejet en aval.
    func diagnostics() -> String {
        guard let context = storedContext else { return "contexte du tap indisponible" }
        let status = context.sourceStatus.load(ordering: .relaxed)
        return "callbacks=\(context.callbacks.load(ordering: .relaxed)) prepares=\(context.prepared.load(ordering: .relaxed)) osStatus=\(status) frames=\(context.lastFrames.load(ordering: .relaxed)) flags=\(context.lastFlags.load(ordering: .relaxed))"
    }
}
