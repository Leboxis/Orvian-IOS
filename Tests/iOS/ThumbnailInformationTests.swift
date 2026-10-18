import XCTest
@testable import Orvian

final class ThumbnailInformationTests: XCTestCase {
    func testMeasuresEncodedPixelsAndBytesWithinTheCurrentAccountAndDrive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskImageCache(directory: directory)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        cache.store(data: png, credentialFingerprint: "account-a", driveId: 42, fileId: 1, isTrashed: false)
        cache.store(data: png, credentialFingerprint: "account-a", driveId: 42, fileId: 1, isTrashed: true)
        cache.store(data: png, credentialFingerprint: "account-b", driveId: 42, fileId: 2, isTrashed: false)
        cache.store(data: png, credentialFingerprint: "account-a", driveId: 43, fileId: 3, isTrashed: false)
        let information = cache.thumbnailInformation(credentialFingerprint: "account-a", driveId: 42)
        XCTAssertEqual(information.count, 2)
        XCTAssertEqual(Set(information.map(\.id)).count, 2)
        for item in information {
            XCTAssertEqual(item.fileId, 1)
            XCTAssertEqual(item.width, 1)
            XCTAssertEqual(item.height, 1)
            XCTAssertEqual(item.byteCount, png.count)
        }
    }
}
