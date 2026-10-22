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
        case .english: "Langue originale (transcription)"
        case .french: "Français (traduction automatique)"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: "CC"
        case .english: "VO"
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
    /// Instant où le texte devient disponible, distinct de la parole si le
    /// moteur a du retard. La durée de lecture doit partir de cet instant.
    var displayStart: Double? = nil
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
        return time - (latest.displayStart ?? latest.start) <= maximumAge ? latest : nil
    }
}

/// Langue parlée choisie explicitement ; Speech vérifie sa disponibilité réelle.
enum SubtitleSourceLanguage: String, CaseIterable, Identifiable, Sendable, Codable {
    case english = "en", french = "fr", spanish = "es", german = "de", italian = "it", portuguese = "pt"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .english: "Anglais"
        case .french: "Français"
        case .spanish: "Espagnol"
        case .german: "Allemand"
        case .italian: "Italien"
        case .portuguese: "Portugais"
        }
    }
    var localeIdentifier: String {
        switch self {
        case .english: "en-US"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .german: "de-DE"
        case .italian: "it-IT"
        case .portuguese: "pt-PT"
        }
    }
}

/// Regroupe uniquement les fragments définitifs. Un délai côté lecteur vide le
/// reliquat lors d'un silence ; les limites évitent d'accumuler un monologue.
struct SubtitleSentenceBuffer: Sendable {
    private var pending: SubtitleCue?

    mutating func append(_ cue: SubtitleCue) -> SubtitleCue? {
        guard cue.isFinal, !cue.text.isEmpty else { return nil }
        if var current = pending {
            current.text += " " + cue.text
            current.end = cue.end
            pending = current
        } else {
            pending = cue
        }
        guard let current = pending else { return nil }
        if current.text.last.map({ ".!?…。！？".contains($0) }) == true
            || current.text.count >= 240 || current.end - current.start >= 5 {
            return flush()
        }
        return nil
    }

    mutating func flush() -> SubtitleCue? {
        defer { pending = nil }
        return pending
    }
}

/// La traduction active reste hors de cette file. En surcharge, seuls les
/// anciens éléments encore en attente sont évincés pour limiter le retard.
struct SubtitleTranslationQueue: Sendable {
    private var pending: [SubtitleCue] = []
    var count: Int { pending.count }
    mutating func append(_ cue: SubtitleCue) {
        pending.append(cue)
        if pending.count > 4 { pending.removeFirst(pending.count - 4) }
    }
    mutating func popFirst() -> SubtitleCue? {
        pending.isEmpty ? nil : pending.removeFirst()
    }
    mutating func clear() { pending.removeAll() }
}
