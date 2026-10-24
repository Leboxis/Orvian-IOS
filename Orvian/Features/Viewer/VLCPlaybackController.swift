import SwiftUI
import MobileVLCKit

/// Only created after AVPlayer reports an unsupported format/decoder.
@MainActor
final class VLCPlaybackController: NSObject, VLCMediaPlayerDelegate {
    enum Event { case playing, buffering, ended, failed }

    let url: URL
    private(set) var hasEnded = false
    private let player = VLCMediaPlayer()
    private var hasStarted = false
    private var inputDidStop = false
    private var wantsPlayback = false
    private var pendingPosition: Double?
    private var stopping = false
    private var bufferingTimeout: Task<Void, Never>?
    // libVLC stops asynchronously: never deallocate its player/drawable mid-stop.
    private static var retiring: [ObjectIdentifier: VLCPlaybackController] = [:]
    var onTime: ((Double, Double) -> Void)?
    var onEvent: ((Event) -> Void)?
    var rate: Float = 1 {
        didSet { player.rate = rate }
    }
    var isMuted = false {
        didSet { player.audio?.isMuted = isMuted }
    }
    var currentTime: Double { max(0, Double(player.time.intValue) / 1_000) }
    var duration: Double { max(0, Double(player.media?.length.intValue ?? 0) / 1_000) }
    var isSeekable: Bool { player.isSeekable }
    var isRestoringPosition: Bool { pendingPosition != nil }

    init(url: URL, resumePosition: Double?) {
        self.url = url
        pendingPosition = resumePosition
        super.init()
        let media = VLCMedia(url: url)
        // Prefer VideoToolbox/hardware where supported; software remains a codec fallback.
        media.addOption(":avcodec-hw=any")
        media.addOption(":network-caching=1500")
        player.media = media
        player.delegate = self
    }

    func attach(to view: UIView) {
        guard !stopping, !hasStarted else { return }
        player.drawable = view
        hasStarted = true
        inputDidStop = false
        // Opening the input is needed even when a recovered session is paused.
        player.play()
        startBufferingTimeout()
    }

    func play() {
        guard !stopping, !hasEnded else { return }
        wantsPlayback = true
        if hasStarted {
            inputDidStop = false
            player.play()
            if player.state == .opening || player.state == .buffering { startBufferingTimeout() }
        }
    }

    func pause() {
        bufferingTimeout?.cancel()
        bufferingTimeout = nil
        wantsPlayback = false
        if hasStarted { player.pause() }
    }

    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard !stopping, player.isSeekable, seconds.isFinite else { return false }
        let upper = duration > 0 ? duration : Double(Int32.max) / 1_000
        let milliseconds = Int32(min(min(max(0, seconds), upper) * 1_000, Double(Int32.max)))
        pendingPosition = nil
        player.time = VLCTime(int: milliseconds)
        return true
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        bufferingTimeout?.cancel()
        bufferingTimeout = nil
        wantsPlayback = false
        onTime = nil
        onEvent = nil
        if !hasStarted || inputDidStop {
            finishStop()
        } else {
            Self.retiring[ObjectIdentifier(self)] = self
            player.stop()
        }
    }

    private func finishStop() {
        player.delegate = nil
        player.drawable = nil
        Self.retiring[ObjectIdentifier(self)] = nil
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        guard let source = notification.object as? VLCMediaPlayer else { return }
        let state = source.state
        Task { @MainActor [weak self] in
            guard let self, self.player === source else { return }
            self.stateChanged(state)
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            self.restorePositionIfPossible()
            self.onTime?(self.currentTime, self.duration)
        }
    }

    private func restorePositionIfPossible() {
        if let position = pendingPosition, seek(to: position) { pendingPosition = nil }
    }

    private func startBufferingTimeout() {
        guard bufferingTimeout == nil, wantsPlayback, !stopping else { return }
        bufferingTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, !self.stopping, self.wantsPlayback else { return }
            self.bufferingTimeout = nil
            self.onEvent?(.failed)
        }
    }

    private func stateChanged(_ state: VLCMediaPlayerState) {
        if state == .stopped { inputDidStop = true }
        if stopping {
            if state == .stopped { finishStop() }
            return
        }
        switch state {
        case .opening, .buffering:
            startBufferingTimeout()
            onEvent?(.buffering)
        case .playing:
            bufferingTimeout?.cancel()
            bufferingTimeout = nil
            player.audio?.isMuted = isMuted
            player.rate = rate
            restorePositionIfPossible()
            if !wantsPlayback { player.pause() }
            onEvent?(.playing)
        case .ended:
            hasEnded = true
            wantsPlayback = false
            onEvent?(.ended)
        case .error:
            wantsPlayback = false
            onEvent?(.failed)
        default:
            break
        }
    }
}

struct VLCVideoSurface: UIViewRepresentable {
    let playback: VLCPlaybackController

    func makeCoordinator() -> VLCPlaybackController { playback }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Defer attachment: libVLC may emit callbacks while SwiftUI is updating.
        Task { @MainActor in playback.attach(to: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: VLCPlaybackController) {
        coordinator.stop()
    }
}
