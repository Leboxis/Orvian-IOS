import XCTest
@testable import Orvian

final class ContentClassificationTests: XCTestCase {
    func testExplicitContentHasPriorityAndMissingScoresRemainUnscanned() {
        let snapshot = ImageClassificationSnapshot(scores: [
            1: .init(nudity: 0.6, semen: 0.1, feet: 0.9),
            2: .init(nudity: 0.1, semen: 0.6, feet: 0.9),
            3: .init(nudity: 0.1, semen: 0.1, feet: 0.9),
            4: .init(nudity: 0.1, semen: 0.1, feet: 0.1),
            5: .init(nudity: 0, semen: .nan, feet: 0)
        ])
        XCTAssertEqual(snapshot.classification(for: 1, threshold: 0.5), .nsfw)
        XCTAssertEqual(snapshot.classification(for: 2, threshold: 0.5), .nsfw)
        XCTAssertEqual(snapshot.classification(for: 3, threshold: 0.5), .feet)
        XCTAssertEqual(snapshot.classification(for: 4, threshold: 0.5), .sfw)
        XCTAssertEqual(snapshot.classification(for: 5, threshold: 0.5), .unscanned)
        XCTAssertEqual(snapshot.classification(for: 6, threshold: 0.5), .unscanned)
    }

    func testNudeNetUsesWinningClassAndClassAgnosticNMS() throws {
        // Identical face / breast boxes: the lower-scoring breast is suppressed.
        // Feet on the other side survive; covered feet aren't counted as bare feet.
        let candidates: [(Float, Float, Float, Float, Int, Float)] = [
            (60, 60, 40, 40, 1, 0.95), (60, 60, 40, 40, 3, 0.8),
            (220, 220, 40, 40, 7, 0.75), (150, 150, 20, 20, 9, 0.9)
        ]
        let result = try NudeNetPostprocessor.scores(candidateCount: candidates.count,
            contentWidth: 320, contentHeight: 320) { channel, index in
                let candidate = candidates[index]
                switch channel {
                case 0: return candidate.0
                case 1: return candidate.1
                case 2: return candidate.2
                case 3: return candidate.3
                default: return channel - 4 == candidate.4 ? candidate.5 : 0.01
                }
            }
        XCTAssertEqual(result.nudity, 0)
        XCTAssertEqual(result.feet, 0.75)
    }

    func testPaddingOnlyDetectionIsExcludedAndInvalidOutputThrows() throws {
        let result = try NudeNetPostprocessor.scores(candidateCount: 1,
            contentWidth: 160, contentHeight: 320) { channel, _ in
                [Float(250), 160, 20, 20][safe: channel] ?? (channel == 11 ? 0.9 : 0)
            }
        XCTAssertEqual(result.feet, 0)
        XCTAssertThrowsError(try NudeNetPostprocessor.scores(candidateCount: 1,
            contentWidth: 320, contentHeight: 320) { _, _ in .nan })
        XCTAssertThrowsError(try NudeNetPostprocessor.scores(candidateCount: 1,
            contentWidth: 320, contentHeight: 320) { channel, _ in channel == 0 ? .nan : 0 })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
