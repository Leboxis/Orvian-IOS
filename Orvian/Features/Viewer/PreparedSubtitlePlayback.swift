import Foundation
import Observation

@MainActor @Observable
final class PreparedSubtitlePlayback {
    private(set) var isAvailable = false
    private(set) var mode: SubtitleMode = .french
    private(set) var cue: SubtitleCue?
    @ObservationIgnored private var document: PreparedSubtitles?

    func install(_ document: PreparedSubtitles?) {
        self.document = document
        isAvailable = document != nil
        mode = .french
        cue = nil
    }

    func setMode(_ mode: SubtitleMode, at time: Double) {
        self.mode = mode
        refresh(at: time)
    }

    func refresh(at time: Double) {
        let next = document?.cue(at: time, mode: mode)
        if next != cue { cue = next }
    }
}
