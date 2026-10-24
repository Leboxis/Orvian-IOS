import Foundation

// Only file metadata is substituted; cue lookup and playback are production code.
struct DriveFile {
    let id: Int
    let size: Int? = 100
    let lastModifiedAt: Double? = 10
    let updatedAt: Double? = 10
}

@main
struct PreparedSubtitlePlaybackChecks {
    @MainActor
    static func main() {
        let key = PreparedSubtitleKey(credential: "accountA", driveID: 1,
                                      file: DriveFile(id: 42), source: .english)
        let document = PreparedSubtitles(key: key, createdAt: Date(), cues: [
            .init(start: 2, end: 4, original: "Hello.", french: "Bonjour."),
            .init(start: 6, end: 8, original: "Goodbye.", french: "Au revoir.")
        ])
        precondition(document.isValid)
        let playback = PreparedSubtitlePlayback()
        playback.install(document)
        // An AVPlayer/VLC media clock uses the same source-time lookup.
        for (time, expected) in [(0.0, nil), (2, "Bonjour."), (3.9, "Bonjour."),
                                 (4, nil), (6.5, "Au revoir."), (8, nil),
                                 (2.5, "Bonjour.")] as [(Double, String?)] {
            playback.refresh(at: time)
            precondition(playback.cue?.text == expected)
        }
        playback.setMode(.english, at: 6.5)
        precondition(playback.cue?.text == "Goodbye.")
        playback.setMode(.off, at: 6.5)
        playback.refresh(at: 2.5)
        precondition(playback.cue == nil)
        playback.setMode(.french, at: 2.5)
        precondition(playback.cue?.text == "Bonjour.")
        playback.refresh(at: .nan)
        precondition(playback.cue == nil)
        playback.install(nil)
        precondition(!playback.isAvailable && playback.cue == nil)
        print("PASS: prepared subtitle media-clock playback checks")
    }
}
