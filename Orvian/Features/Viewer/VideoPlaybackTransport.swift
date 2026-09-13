/// Intention de transport indépendante des pauses techniques d'AVPlayer.
/// Les callbacks de recherche ne peuvent valider que la dernière demande.
struct VideoPlaybackTransport {
    private(set) var wantsPlayback = false
    private(set) var isScrubbing = false
    private(set) var pendingSeekID: Int?
    private(set) var recoveryPosition: Double?
    private var generation = 0

    var isSeeking: Bool { pendingSeekID != nil }

    mutating func play() { wantsPlayback = true }
    mutating func pause() { wantsPlayback = false }

    mutating func rememberRecoveryPosition(_ position: Double) {
        // Un remplacement qui échoue à zéro ne doit pas perdre le point initial.
        guard recoveryPosition == nil else { return }
        recoveryPosition = position.isFinite ? max(0, position) : 0
    }

    mutating func clearRecoveryPosition() { recoveryPosition = nil }

    mutating func beginScrub() {
        cancelSeek()
        isScrubbing = true
    }

    /// Idempotent : une annulation et une fin normale ne terminent pas deux fois.
    mutating func endScrub() -> Bool {
        guard isScrubbing else { return false }
        isScrubbing = false
        return true
    }

    mutating func beginSeek() -> Int {
        cancelSeek()
        pendingSeekID = generation
        return generation
    }

    func acceptsSeek(_ id: Int) -> Bool { pendingSeekID == id }

    /// La pause demandée pendant la recherche prime sur l'intention de départ.
    mutating func finishSeek(_ id: Int, finished: Bool) -> Bool {
        guard acceptsSeek(id) else { return false }
        pendingSeekID = nil
        // Une erreur peut interrompre la recherche avant le remplacement du
        // lecteur : préserver l'intention pour cette récupération.
        return finished && wantsPlayback && !isScrubbing
    }

    mutating func cancelSeek() {
        generation &+= 1
        pendingSeekID = nil
    }

    mutating func reset(preservingPlaybackIntent: Bool = false) {
        cancelSeek()
        isScrubbing = false
        if !preservingPlaybackIntent {
            pause()
            clearRecoveryPosition()
        }
    }
}
