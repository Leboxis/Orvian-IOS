// Compiled with the production controller and controlled libVLC stand-ins.
import Foundation

@MainActor
final class UIView: NSObject {}

protocol VLCMediaPlayerDelegate: AnyObject {
    func mediaPlayerStateChanged(_ notification: Notification)
    func mediaPlayerTimeChanged(_ notification: Notification)
}

enum VLCMediaPlayerState { case stopped, opening, buffering, ended, error, playing, paused, esAdded }

final class VLCTime {
    let intValue: Int32
    init(int value: Int32) { intValue = value }
}

final class VLCAudio { var isMuted = false }

final class VLCMedia {
    let url: URL
    var length = VLCTime(int: 120_000)
    var options: [String] = []
    init(url: URL) { self.url = url }
    func addOption(_ option: String) { options.append(option) }
}

@MainActor
final class VLCMediaPlayer {
    static weak var latest: VLCMediaPlayer?
    weak var delegate: VLCMediaPlayerDelegate?
    // Like the Objective-C API, the cached state can be read in its delegate.
    nonisolated(unsafe) var state: VLCMediaPlayerState = .stopped
    var media: VLCMedia?
    var audio: VLCAudio? = VLCAudio()
    var time = VLCTime(int: 0)
    var isSeekable = false
    var rate: Float = 1
    var playCalls = 0
    var pauseCalls = 0
    var stopCalls = 0
    var onDrawableReleased: (() -> Void)?
    var drawable: AnyObject? {
        didSet { if drawable == nil { onDrawableReleased?() } }
    }
    init() { Self.latest = self }
    func play() { playCalls += 1 }
    func pause() { pauseCalls += 1 }
    // Deliberately no immediate state change: real 3.7.4 stop is asynchronous.
    func stop() { stopCalls += 1 }
    func emit(_ next: VLCMediaPlayerState) {
        state = next
        delegate?.mediaPlayerStateChanged(Notification(name: Notification.Name("state"), object: self))
    }
    func emitTime() {
        delegate?.mediaPlayerTimeChanged(Notification(name: Notification.Name("time"), object: self))
    }
}

// The runner compiles these checks in the controller's source file.
extension VLCPlaybackController {
    var hasPendingBufferingTimeout: Bool { bufferingTimeout != nil }
}

@main
struct VLCPlaybackChecks {
    @MainActor
    static func main() async {
        await checkPausedAttachmentAndConfiguration()
        await checkAudioAppearingAfterPreparation()
        await checkProgressOverridesBufferingNotifications()
        await checkPendingResumeAndSeekBounds()
        await checkStopBeforeFirstStateDelivery()
        await checkRetainedStopAndStaleCallbacks()
        await checkEndedReplay()
        print("PASS: VLC controller behavioral checks")
    }

    @MainActor
    static func make(_ position: Double? = nil) -> (VLCPlaybackController, VLCMediaPlayer) {
        let controller = VLCPlaybackController(url: URL(string: "https://example.invalid/video.mkv")!, resumePosition: position)
        return (controller, VLCMediaPlayer.latest!)
    }

    @MainActor
    static func stateEvent(_ state: VLCMediaPlayerState, controller: VLCPlaybackController, player: VLCMediaPlayer) async {
        await withCheckedContinuation { continuation in
            controller.onEvent = { _ in continuation.resume() }
            player.emit(state)
        }
        controller.onEvent = nil
    }

    @MainActor
    static func timeEvent(controller: VLCPlaybackController, player: VLCMediaPlayer) async {
        await withCheckedContinuation { continuation in
            controller.onTime = { _, _ in continuation.resume() }
            player.emitTime()
        }
        controller.onTime = nil
    }

    @MainActor
    static func completeStop(_ player: VLCMediaPlayer) async {
        if player.drawable == nil {
            assert(player.delegate == nil)
            return
        }
        await withCheckedContinuation { continuation in
            player.onDrawableReleased = { continuation.resume() }
            player.emit(.stopped)
        }
        player.onDrawableReleased = nil
    }

    @MainActor
    static func checkPausedAttachmentAndConfiguration() async {
        let (controller, player) = make()
        controller.isMuted = true
        controller.rate = 1.5
        controller.pause()
        controller.attach(to: UIView())
        assert(player.playCalls == 1, "attachment must open input even when paused")
        await stateEvent(.playing, controller: controller, player: player)
        assert(player.pauseCalls == 1, "pause intent before attachment must be preserved")
        assert(player.audio?.isMuted == true && player.rate == 1.5, "mute/rate must survive first playing event")
        assert(player.media?.options.contains(":avcodec-hw=any") == true, "hardware automatic selection must stay enabled")
        controller.attach(to: UIView())
        assert(player.playCalls == 1, "SwiftUI updates must not open a second input")
        controller.play()
        assert(player.playCalls == 2)
        controller.stop()
        await completeStop(player)
    }

    @MainActor
    static func checkAudioAppearingAfterPreparation() async {
        let (controller, player) = make()
        player.audio = nil
        controller.isMuted = true
        controller.play()
        controller.attach(to: UIView())
        await stateEvent(.playing, controller: controller, player: player)
        assert(controller.isMuted, "mute intent survives an unavailable audio interface")
        player.audio = VLCAudio()
        await stateEvent(.playing, controller: controller, player: player)
        assert(player.audio?.isMuted == true, "apply saved mute when audio becomes available")
        controller.isMuted = false
        assert(player.audio?.isMuted == false)
        controller.stop()
        await completeStop(player)
    }

    @MainActor
    static func checkProgressOverridesBufferingNotifications() async {
        let (controller, player) = make()
        controller.play()
        controller.attach(to: UIView())
        await stateEvent(.buffering, controller: controller, player: player)
        assert(controller.hasPendingBufferingTimeout)
        player.time = VLCTime(int: 1_000)
        await timeEvent(controller: controller, player: player)
        var progressEvents = 0
        controller.onEvent = { event in
            if case .playing = event { progressEvents += 1 }
        }
        player.time = VLCTime(int: 2_000)
        await timeEvent(controller: controller, player: player)
        assert(progressEvents == 1, "real playback must dismiss the buffering indicator")
        assert(!controller.hasPendingBufferingTimeout, "a playing video must not hit the 20s buffering cutoff")
        // Buffer-fill notifications during live video must not flash a spinner.
        var bufferingEvents = 0
        controller.onEvent = { event in
            if case .buffering = event { bufferingEvents += 1 }
        }
        player.emit(.buffering)
        await timeEvent(controller: controller, player: player) // unchanged media time
        assert(bufferingEvents == 0)
        // A subsequent real stall must still be protected, even after playback worked.
        assert(controller.hasPendingBufferingTimeout, "repeated timestamps do not prove playback")
        player.time = VLCTime(int: 3_000)
        await timeEvent(controller: controller, player: player)
        assert(!controller.hasPendingBufferingTimeout)
        player.isSeekable = true
        await stateEvent(.buffering, controller: controller, player: player)
        assert(controller.seek(to: 20))
        await timeEvent(controller: controller, player: player)
        assert(controller.hasPendingBufferingTimeout, "a seek jump alone must not dismiss a real stall")
        player.time = VLCTime(int: 20_500)
        await timeEvent(controller: controller, player: player)
        assert(!controller.hasPendingBufferingTimeout)
        controller.stop()
        await completeStop(player)
    }

    @MainActor
    static func checkPendingResumeAndSeekBounds() async {
        let (controller, player) = make(42)
        controller.play()
        controller.attach(to: UIView())
        await stateEvent(.playing, controller: controller, player: player)
        assert(player.time.intValue == 0, "do not seek an unseekable input")
        player.isSeekable = true
        await timeEvent(controller: controller, player: player)
        assert(player.time.intValue == 42_000, "restore position once input becomes seekable")
        player.time = VLCTime(int: 15_000)
        await timeEvent(controller: controller, player: player)
        assert(player.time.intValue == 15_000, "pending resume must be consumed once")
        assert(!controller.seek(to: .nan) && !controller.seek(to: .infinity))
        assert(controller.seek(to: -2) && player.time.intValue == 0)
        assert(controller.seek(to: 999) && player.time.intValue == 120_000)
        controller.stop()
        await completeStop(player)
    }

    @MainActor
    static func checkStopBeforeFirstStateDelivery() async {
        let (controller, player) = make()
        let view = UIView()
        controller.play()
        controller.attach(to: view)
        // Cached state remains stopped until the asynchronous opening callback.
        assert(player.state == .stopped)
        controller.stop()
        assert(player.stopCalls == 1, "a started input must stop even while cached state is initially stopped")
        assert(player.drawable === view && player.delegate != nil, "do not release an input before its stop callback")
        await completeStop(player)
        assert(player.drawable == nil && player.delegate == nil)
    }

    @MainActor
    static func checkRetainedStopAndStaleCallbacks() async {
        var controller: VLCPlaybackController? = make().0
        let player = VLCMediaPlayer.latest!
        weak var weakController = controller
        var view: UIView? = UIView()
        weak var weakView = view
        controller!.play()
        controller!.attach(to: view!)
        await stateEvent(.playing, controller: controller!, player: player)
        var unwantedEvents = 0
        controller!.onEvent = { _ in unwantedEvents += 1 }
        controller!.onTime = { _, _ in unwantedEvents += 1 }
        // Enqueue callbacks, then retire before the delegate task can run.
        player.emitTime()
        player.emit(.buffering)
        controller!.stop()
        let stopCalls = player.stopCalls
        controller!.stop()
        assert(player.stopCalls == stopCalls, "stop must be idempotent")
        controller = nil
        view = nil
        assert(weakController != nil && weakView != nil, "retain controller and drawable through async stop")
        await completeStop(player)
        assert(unwantedEvents == 0, "queued callbacks must not update retired views")
        assert(weakController == nil && weakView == nil, "release retirement ownership on stopped event")
    }

    @MainActor
    static func checkEndedReplay() async {
        let (controller, player) = make()
        controller.play()
        controller.attach(to: UIView())
        player.isSeekable = true
        await stateEvent(.playing, controller: controller, player: player)
        // Deliver EOF and input death together, as libVLC can do on its event queue.
        // The following time callback is a deterministic completion signal, not a sleep.
        await withCheckedContinuation { continuation in
            controller.onTime = { _, _ in continuation.resume() }
            player.emit(.ended)
            player.emit(.stopped)
            player.emitTime()
        }
        controller.onTime = nil
        // The view replaces this ended wrapper, rather than playing its dead input.
        player.isSeekable = false
        assert(controller.hasEnded)
        let playCalls = player.playCalls
        controller.play()
        assert(player.playCalls == playCalls, "EOF must not replay a dead libVLC input")
        let url = controller.url
        controller.stop()
        await completeStop(player)
        let replacement = VLCPlaybackController(url: url, resumePosition: 0)
        let replacementPlayer = VLCMediaPlayer.latest!
        replacement.play()
        replacement.attach(to: UIView())
        assert(replacementPlayer.playCalls == 1 && !replacement.hasEnded)
        replacementPlayer.isSeekable = true
        await stateEvent(.playing, controller: replacement, player: replacementPlayer)
        assert(replacementPlayer.time.intValue == 0)
        replacement.stop()
        await completeStop(replacementPlayer)
    }
}
