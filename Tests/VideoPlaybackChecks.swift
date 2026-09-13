@main
struct VideoPlaybackChecks {
    static func main() {
        // Lecture -> deux scrubs rapides : seul le dernier peut reprendre.
        var playing = VideoPlaybackTransport()
        playing.play()
        playing.beginScrub()
        precondition(playing.endScrub())
        let first = playing.beginSeek()
        playing.beginScrub()
        precondition(!playing.finishSeek(first, finished: false))
        precondition(playing.isScrubbing && playing.wantsPlayback)
        precondition(playing.endScrub())
        let second = playing.beginSeek()
        precondition(!playing.finishSeek(first, finished: true))
        precondition(playing.isSeeking)
        precondition(playing.finishSeek(second, finished: true))
        precondition(!playing.isSeeking)

        // Une vidéo en pause reste en pause après déplacement ou annulation.
        var paused = VideoPlaybackTransport()
        paused.beginScrub()
        precondition(paused.endScrub())
        let pausedSeek = paused.beginSeek()
        precondition(!paused.finishSeek(pausedSeek, finished: true))
        paused.beginScrub()
        precondition(paused.endScrub())
        paused.cancelSeek()
        precondition(!paused.wantsPlayback && !paused.isSeeking && !paused.isScrubbing)

        // Annulation système : on sort du scrub une seule fois, sans perdre
        // l'intention, même si une fin normale arrive ensuite.
        playing.beginScrub()
        precondition(playing.endScrub())
        playing.cancelSeek()
        precondition(!playing.endScrub())
        precondition(playing.wantsPlayback && !playing.isSeeking && !playing.isScrubbing)

        // Pause / tags / casque retiré pendant la recherche : son achèvement
        // ne doit jamais restaurer l'intention qui précédait la pause.
        do {
            playing.play()
            playing.beginScrub()
            precondition(playing.endScrub())
            let seek = playing.beginSeek()
            playing.pause()
            precondition(!playing.finishSeek(seek, finished: true))
            precondition(!playing.wantsPlayback && !playing.isSeeking)
        }

        // Rejouer depuis la fin puis saisir la barre avant le retour à zéro.
        for finished in [false, true] {
            playing.play()
            let replay = playing.beginSeek()
            playing.beginScrub()
            precondition(!playing.finishSeek(replay, finished: finished))
            precondition(playing.isScrubbing && playing.wantsPlayback)
            precondition(playing.endScrub())
        }

        // Une demande Lecture pendant le seek attend le dernier callback.
        paused.beginScrub()
        precondition(paused.endScrub())
        let resume = paused.beginSeek()
        paused.play()
        precondition(paused.isSeeking)
        precondition(paused.finishSeek(resume, finished: true))
        precondition(!paused.finishSeek(resume, finished: true), "Duplicate completion")

        // Remplacement du lecteur après erreur : conserver lecture/pause,
        // mais rendre tous les callbacks de l'ancien lecteur caducs.
        for shouldPlay in [false, true] {
            var recovery = VideoPlaybackTransport()
            if shouldPlay { recovery.play() }
            recovery.rememberRecoveryPosition(185.25)
            let oldSeek = recovery.beginSeek()
            recovery.reset(preservingPlaybackIntent: true)
            precondition(recovery.wantsPlayback == shouldPlay)
            recovery.rememberRecoveryPosition(0)
            precondition(recovery.recoveryPosition == 185.25, "Retry must keep the original position")
            let restoration = recovery.beginSeek()
            precondition(!recovery.finishSeek(oldSeek, finished: true))
            precondition(recovery.finishSeek(restoration, finished: true) == shouldPlay)
            let inFlight = recovery.beginSeek()
            recovery.reset()
            precondition(!recovery.finishSeek(inFlight, finished: true))
            precondition(!recovery.wantsPlayback && !recovery.isSeeking)
            precondition(recovery.recoveryPosition == nil)
        }

        // Une action plus récente peut remplacer le point de récupération.
        paused.rememberRecoveryPosition(185.25)
        paused.clearRecoveryPosition()
        paused.rememberRecoveryPosition(260)
        precondition(paused.recoveryPosition == 260)
        for invalidPosition in [Double.nan, .infinity, -.infinity, -10] {
            paused.clearRecoveryPosition()
            paused.rememberRecoveryPosition(invalidPosition)
            precondition(paused.recoveryPosition == 0)
        }

        // Une recherche échouée ne reprend pas, mais la récupération suivante
        // doit encore connaître l'intention de lecture qui précédait l'erreur.
        playing.play()
        let failed = playing.beginSeek()
        precondition(!playing.finishSeek(failed, finished: false))
        precondition(!playing.isSeeking && playing.wantsPlayback)
        print("Video playback transport checks passed")
    }
}
