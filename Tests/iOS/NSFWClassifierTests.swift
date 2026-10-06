import XCTest
import CoreML
import Vision
import UIKit
@testable import Orvian

@MainActor
final class NSFWClassifierTests: XCTestCase {
    func testBundledModelProducesNormalizedProbabilities() async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 384)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 384, height: 384))
        }
        let classifier = NSFWClassifier()
        try await classifier.prepare()
        let score = try await classifier.classify(imageData: data)
        XCTAssertTrue(score.isFinite)
        XCTAssertTrue((0...1).contains(score))
        let url = try XCTUnwrap(Bundle(for: NSFWClassifierTests.self)
            .url(forResource: "NSFWClassifier", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "NSFWClassifier", withExtension: "mlmodelc"))
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url))
        let request = VNCoreMLRequest(model: model)
        try VNImageRequestHandler(data: data).perform([request])
        let results = try XCTUnwrap(request.results as? [VNClassificationObservation])
        XCTAssertEqual(Set(results.map(\.identifier)), ["NSFW", "SFW"])
        XCTAssertEqual(results.reduce(Float.zero) { $0 + $1.confidence }, 1, accuracy: 0.001)
    }

    func testUnreadableImageThrows() async throws {
        let classifier = NSFWClassifier()
        do {
            _ = try await classifier.classify(imageData: Data([0, 1, 2]))
            XCTFail("Unreadable images must not receive a SFW score")
        } catch { }
    }
}
