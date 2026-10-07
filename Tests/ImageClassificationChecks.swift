import Foundation

@main
struct ImageClassificationChecks {
    static func main() {
        let snapshot = ImageClassificationSnapshot(scores: [
            1: .init(nudity: 0.79, semen: 0.1, feet: 0.1),
            2: .init(nudity: 0.80, semen: 0.1, feet: 0.99),
            3: .init(nudity: .nan, semen: 0, feet: 0),
            4: .init(nudity: 0, semen: .infinity, feet: 0),
            5: .init(nudity: 0, semen: 0, feet: -1),
            6: .init(nudity: 0, semen: 2, feet: 0),
            8: .init(nudity: 0.1, semen: 0.8, feet: 0.99),
            9: .init(nudity: 0.1, semen: 0.1, feet: 0.8)
        ])
        precondition(snapshot.classification(for: 1, threshold: 0.80) == .sfw)
        precondition(snapshot.classification(for: 2, threshold: 0.80) == .nsfw)
        for id in 3...7 { precondition(snapshot.classification(for: id, threshold: 0.80) == .unscanned) }
        precondition(snapshot.classification(for: 2, threshold: 0.90) == .feet)
        precondition(snapshot.classification(for: 8, threshold: 0.80) == .nsfw)
        precondition(snapshot.classification(for: 9, threshold: 0.80) == .feet)
        precondition(snapshot.classification(for: 9, threshold: 0.90) == .sfw)
        precondition(snapshot.classification(for: 2, threshold: .nan) == .unscanned)
        let legacy = Data("{\"score\":0.9,\"fileSize\":10,\"modelVersion\":\"marqo\",\"analyzedAt\":0}".utf8)
        let legacyRecord = try! JSONDecoder().decode(ImageClassificationRecord.self, from: legacy)
        precondition(legacyRecord.scores == nil)
        precondition(ImageContentRevision(size: 10, lastModifiedAt: 1, updatedAt: 1)
            != ImageContentRevision(size: 10, lastModifiedAt: 2, updatedAt: 1))
        print("Image classification thresholds and invalid scores checks passed")
    }
}
