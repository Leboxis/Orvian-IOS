"""Subtitle cue behaviour: stable text, no pile-up, no stale captions."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Orvian/Core/Media/SubtitleCue.swift"

CHECKS = r'''
@main
struct SubtitleCueChecks {
    static func main() {
        // Un provisoire est remplacé par le définitif de la même phrase.
        var timeline = SubtitleCueTimeline()
        timeline.upsert(SubtitleCue(start: 10, end: 12, text: "Today we will", isFinal: false, isTranslated: false))
        timeline.upsert(SubtitleCue(start: 10.2, end: 12.2, text: "Today we will talk", isFinal: true, isTranslated: false))
        assert(timeline.cues.count == 1, "Provisional and final of one phrase must not stack")
        assert(timeline.cues[0].text == "Today we will talk")

        // Un provisoire plus pauvre ne doit pas écraser un définitif.
        timeline.upsert(SubtitleCue(start: 10.1, end: 11, text: "Today", isFinal: false, isTranslated: false))
        assert(timeline.cues[0].text == "Today we will talk")
        assert(timeline.cues[0].isFinal)

        // La traduction remplace le texte anglais au même instant.
        timeline.upsert(SubtitleCue(start: 10, end: 12, text: "Aujourd'hui nous parlerons", isFinal: true, isTranslated: true))
        assert(timeline.cues[0].text == "Aujourd'hui nous parlerons")
        assert(timeline.cues[0].isTranslated)

        // Deux phrases distinctes restent séparées.
        timeline.upsert(SubtitleCue(start: 20, end: 22, text: "Second phrase", isFinal: true, isTranslated: false))
        assert(timeline.cues.count == 2)

        // Le cue le plus récent déjà commencé est celui affiché.
        assert(timeline.cue(at: 21)?.text == "Second phrase")
        assert(timeline.cue(at: 10.5)?.text == "Aujourd'hui nous parlerons")

        // Un sous-titre ancien ne reste pas pendant un long silence.
        assert(timeline.cue(at: 60) == nil, "A stale caption must disappear")

        // Avant le début, rien.
        var empty = SubtitleCueTimeline()
        assert(empty.cue(at: 5) == nil)
        empty.upsert(SubtitleCue(start: 10, end: 12, text: "Later", isFinal: true, isTranslated: false))
        assert(empty.cue(at: 9.8)?.text == "Later", "A cue may appear just ahead of the read position")
        assert(empty.cue(at: 9) == nil)

        // Mémoire bornée : les anciens cues sont évincés.
        var bounded = SubtitleCueTimeline()
        for index in 0..<100 {
            let start = Double(index)
            bounded.upsert(SubtitleCue(start: start, end: start + 1, text: "c\(index)", isFinal: true, isTranslated: false))
        }
        assert(bounded.cues.count <= 40, "Cue history must stay bounded")
        assert(bounded.cue(at: 99)?.text == "c99")

        var cleared = bounded
        cleared.clear()
        assert(cleared.cues.isEmpty)

        // Modes proposés par le bouton CC.
        assert(SubtitleMode.allCases == [.off, .english, .french])
        assert(SubtitleMode.off.title == "Sous-titres désactivés")
        assert(SubtitleMode.french.title == "Français (traduction automatique)")
        print("Subtitle cue checks passed")
    }
}
'''


class SubtitleCueTests(unittest.TestCase):
    def test_cue_timeline_behaviour_on_the_real_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            combined = directory / "checks.swift"
            combined.write_text(SOURCE.read_text(encoding="utf-8") + "\n" + CHECKS, encoding="utf-8")
            executable = directory / "subtitle-cues"
            subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                            str(combined), "-o", str(executable)],
                           check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == "__main__":
    unittest.main()
