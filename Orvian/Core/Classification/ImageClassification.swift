import Foundation

enum ImageSafety: String, Codable, Sendable {
    case sfw, nsfw, unscanned
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
    let contentRevision: ImageContentRevision?
    let fileSize: Int?
    let modelVersion: String
    let analyzedAt: Date
}

/// Values only; safe to read from the shared filtering pass.
struct ImageClassificationSnapshot: Sendable {
    private let scores: [Int: Float]

    init(scores: [Int: Float] = [:]) {
        self.scores = scores.filter { $0.value.isFinite && (0...1).contains($0.value) }
    }

    func score(for fileID: Int) -> Float? { scores[fileID] }

    func classification(for fileID: Int, threshold: Float) -> ImageSafety {
        guard let score = score(for: fileID), threshold.isFinite, (0...1).contains(threshold) else {
            return .unscanned
        }
        return score >= threshold ? .nsfw : .sfw
    }
}
