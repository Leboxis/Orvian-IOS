import XCTest
import CoreML
import Vision
import UIKit
@testable import Orvian

@MainActor
final class NSFWClassifierTests: XCTestCase {
    func testTemporaryDiagnoseBundledModelContracts() async throws {
        // TEMPORARY CI diagnostic: pinpoint which classify guard throws invalidModelContract.
        for name in ["NudeNet320n", "JoyTag"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "mlmodelc"))
            let model = try MLModel(contentsOf: url)
            let desc = model.modelDescription
            let meta = desc.metadata[.creatorDefinedKey] as? [String: String]
            print("DIAG \(name) pipeline=\(meta?["orvian.pipelineVersion"] ?? "nil") tag=\(meta?["orvian.tag"] ?? "nil")")
            for input in desc.inputDescriptions {
                if let c = input.imageConstraint {
                    print("DIAG \(name) input \(input.name) \(c.pixelsWide)x\(c.pixelsHigh)")
                } else {
                    print("DIAG \(name) input \(input.name) non-image")
                }
            }
            for output in desc.outputDescriptions {
                if let m = output.multiArrayConstraint {
                    print("DIAG \(name) output \(output.name) shape=\(m.shape) dtype=\(m.dataType.rawValue)")
                } else {
                    print("DIAG \(name) output \(output.name) non-multiarray")
                }
            }
        }
        let classifier = NSFWImageClassifier()
        try await classifier.prepare()
        print("DIAG prepare ok")
        do {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).pngData { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
            }
            let scores = try await classifier.classify(imageData: data)
            print("DIAG classify ok nudity=\(scores.nudity) semen=\(scores.semen) feet=\(scores.feet) valid=\(scores.isValid)")
        } catch {
            print("DIAG classify threw: \(error)")
            throw error
        }
    }

    func testBothBundledModelsProduceIndependentValidScores() async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        let classifier = NSFWImageClassifier()
        try await classifier.prepare()
        let scores = try await classifier.classify(imageData: data)
        XCTAssertTrue(scores.isValid)
        for name in ["NudeNet320n", "JoyTag"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "mlmodelc"))
            let model = try MLModel(contentsOf: url)
            let metadata = try XCTUnwrap(model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
            XCTAssertEqual(metadata["orvian.pipelineVersion"], NSFWImageClassifier.modelVersion)
        }
    }

    func testUnreadableImageThrows() async throws {
        let classifier = NSFWImageClassifier()
        do {
            _ = try await classifier.classify(imageData: Data([0, 1, 2]))
            XCTFail("Unreadable images must not receive a SFW score")
        } catch { }
    }

    func testPaddingPreservesLandscapeAndPortraitContent() throws {
        for dimensions in [CGSize(width: 20, height: 10), CGSize(width: 10, height: 20)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: dimensions, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: dimensions))
            }
            let source = try XCTUnwrap(image.cgImage)
            for centered in [false, true] {
                let size = centered ? 448 : 320
                let padded = try NSFWImageClassifier.paddedImage(source, size: size, centered: centered)
                XCTAssertEqual(padded.width, size)
                XCTAssertEqual(padded.height, size)
                var pixels = [UInt8](repeating: 0, count: size * size * 4)
                try pixels.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(padded, in: CGRect(x: 0, y: 0, width: size, height: size))
                }
                let point = centered ? size / 2 : size / 4
                let center = (point * size + point) * 4
                XCTAssertEqual(pixels[center], 255)
                XCTAssertEqual(pixels[center + 1], 0)
                // Both portrait and landscape have padding at bottom-right.
                let corner = ((size - 2) * size + size - 2) * 4
                XCTAssertEqual(Array(pixels[corner..<corner + 3]), centered ? [255, 255, 255] : [0, 0, 0])
            }
        }
    }

    func testOddJoyTagPaddingUsesIntegerOffsetsInSourceSpace() {
        let landscape = NSFWImageClassifier.contentRect(width: 20, height: 19, size: 448, centered: true)
        XCTAssertEqual(landscape.minY, 0)
        XCTAssertEqual(landscape.height, 425.6, accuracy: 0.0001)
        let portrait = NSFWImageClassifier.contentRect(width: 19, height: 20, size: 448, centered: true)
        XCTAssertEqual(portrait.minX, 0)
        XCTAssertEqual(portrait.width, 425.6, accuracy: 0.0001)
        let offset = NSFWImageClassifier.contentRect(width: 20, height: 17, size: 448, centered: true)
        XCTAssertEqual(offset.minY, 22.4, accuracy: 0.0001)
    }
}
