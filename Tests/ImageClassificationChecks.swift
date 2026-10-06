import Foundation

@main
struct ImageClassificationChecks {
    static func main() {
        let snapshot = ImageClassificationSnapshot(scores: [1: 0.79, 2: 0.80, 3: .nan, 4: .infinity, 5: -1, 6: 2])
        precondition(snapshot.classification(for: 1, threshold: 0.80) == .sfw)
        precondition(snapshot.classification(for: 2, threshold: 0.80) == .nsfw)
        for id in 3...7 { precondition(snapshot.classification(for: id, threshold: 0.80) == .unscanned) }
        precondition(snapshot.classification(for: 2, threshold: 0.90) == .sfw)
        precondition(ImageContentRevision(size: 10, lastModifiedAt: 1, updatedAt: 1)
            != ImageContentRevision(size: 10, lastModifiedAt: 2, updatedAt: 1))
        print("Image classification thresholds and invalid scores checks passed")
    }
}
