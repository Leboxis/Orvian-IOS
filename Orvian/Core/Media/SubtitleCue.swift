import Foundation

/// Choix du menu « CC / Traduction » du lecteur.
enum SubtitleMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case english
    case french

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Sous-titres désactivés"
        case .english: "Anglais (transcription)"
        case .french: "Français (traduction automatique)"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: "CC"
        case .english: "EN"
        case .french: "FR"
        }
    }
}

/// Un sous-titre temporisé sur la timeline média.
struct SubtitleCue: Equatable, Sendable {
    /// Position d'apparition, en secondes de média.
    var start: Double
    /// Fin estimée de la phrase.
    var end: Double
    var text: String
    var isFinal: Bool
    var isTranslated: Bool
}

/// Conserve les sous-titres récents et choisit celui à afficher.
///
/// Le texte arrive après la parole (transcription puis traduction) : exiger que
/// la position média tombe dans l'intervalle du cue n'afficherait presque rien.
/// On affiche donc le cue le plus récent déjà commencé, tant qu'il reste jeune.
struct SubtitleCueTimeline: Sendable {
    private(set) var cues: [SubtitleCue] = []
    /// Un sous-titre déjà ancien ne doit pas rester à l'écran pendant un silence.
    var maximumAge: Double = 6
    /// Tolérance d'avance : un cue peut commencer juste après la position lue.
    var lookahead: Double = 0.5

    /// Insère ou remplace le cue couvrant approximativement le même instant.
    ///
    /// Un résultat provisoire est remplacé par le définitif de la même phrase ;
    /// sans cela, le texte oscillerait et s'empilerait à l'écran.
    mutating func upsert(_ cue: SubtitleCue, tolerance: Double = 0.8) {
        if let index = cues.firstIndex(where: { abs($0.start - cue.start) <= tolerance }) {
            var merged = cue
            // Un définitif ne doit pas régresser vers un texte provisoire plus court.
            if cues[index].isFinal, !cue.isFinal, cues[index].text.count >= cue.text.count {
                merged.text = cues[index].text
                merged.isFinal = true
            }
            if cues[index].isTranslated, !cue.isTranslated, cues[index].text.count >= cue.text.count {
                merged.text = cues[index].text
                merged.isTranslated = true
            }
            cues[index] = merged
        } else {
            cues.append(cue)
        }
        cues.sort { $0.start < $1.start }
        if cues.count > 40 { cues.removeFirst(cues.count - 40) }
    }

    mutating func clear() {
        cues.removeAll()
    }

    /// Cue à afficher à `time`, ou `nil` si le plus récent est trop ancien.
    func cue(at time: Double) -> SubtitleCue? {
        guard let latest = cues.last(where: { $0.start <= time + lookahead }) else { return nil }
        return time - latest.start <= maximumAge ? latest : nil
    }
}
