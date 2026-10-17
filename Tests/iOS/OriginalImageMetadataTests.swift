import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Orvian

final class OriginalImageMetadataTests: XCTestCase {
    func testDimensionsComeFromOriginalPropertiesAndRespectOrientation() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 48, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(HiresImageStore.originalPixelSize(fromFile: url), CGSize(width: 8, height: 12))
        let downsample = try XCTUnwrap(HiresImageStore.decode(fromFile: url, maximumPixelSize: 4))
        XCTAssertLessThanOrEqual(max(downsample.size.width, downsample.size.height) * downsample.scale, 4)
    }
}
