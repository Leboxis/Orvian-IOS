import Foundation

enum ImageSafety: String, Codable, Sendable {
    case sfw, nsfw, feet, unscanned
}

/// Independent scores: NudeNet nudity/feet and JoyTag's `cum` tag.
struct ImageContentScores: Codable, Sendable, Equatable {
    let nudity: Float
    let semen: Float
    let feet: Float

    var explicit: Float { max(nudity, semen) }
    var isValid: Bool {
        [nudity, semen, feet].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    func classification(threshold: Float) -> ImageSafety {
        guard isValid, threshold.isFinite, (0...1).contains(threshold) else { return .unscanned }
        if explicit >= threshold { return .nsfw }
        return feet >= threshold ? .feet : .sfw
    }
}

struct ImageContentRevision: Codable, Hashable, Sendable {
    let size: Int?
    let lastModifiedAt: Double?
    let updatedAt: Double?

    init(size: Int?, lastModifiedAt: Double?, updatedAt: Double?) {
        self.size = size
        self.lastModifiedAt = lastModifiedAt
        self.updatedAt = updatedAt
    }

    init?(file: DriveFile) {
        guard file.lastModifiedAt != nil || file.updatedAt != nil else { return nil }
        self.init(size: file.size, lastModifiedAt: file.lastModifiedAt, updatedAt: file.updatedAt)
    }
}

struct ImageClassificationRecord: Codable, Sendable {
    let score: Float
    // Optional only to decode old Marqo caches. Missing fields are unscanned.
    let semenScore: Float?
    let feetScore: Float?
    let contentRevision: ImageContentRevision?
    let fileSize: Int?
    let modelVersion: String
    let analyzedAt: Date

    var scores: ImageContentScores? {
        guard let semenScore, let feetScore else { return nil }
        let result = ImageContentScores(nudity: score, semen: semenScore, feet: feetScore)
        return result.isValid ? result : nil
    }
}

/// Values only; safe to read from the shared filtering pass.
struct ImageClassificationSnapshot: Sendable {
    private let scores: [Int: ImageContentScores]

    init(scores: [Int: ImageContentScores] = [:]) {
        self.scores = scores.filter { $0.value.isValid }
    }

    func scores(for fileID: Int) -> ImageContentScores? { scores[fileID] }

    func classification(for fileID: Int, threshold: Float) -> ImageSafety {
        scores(for: fileID)?.classification(threshold: threshold) ?? .unscanned
    }
}

enum ClassificationError: LocalizedError {
    case modelUnavailable, invalidImage, invalidScores, invalidPagination, invalidModelContract

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "Les modèles d’analyse sont indisponibles dans cette version de l’app."
        case .invalidImage: return "L’image ne peut pas être analysée."
        case .invalidScores: return "Un modèle n’a pas produit un résultat valide."
        case .invalidPagination: return "Le chargement du dossier est incomplet. Relancez le scan."
        case .invalidModelContract: return "Les modèles d’analyse ne correspondent pas à cette version de l’app."
        }
    }
}
