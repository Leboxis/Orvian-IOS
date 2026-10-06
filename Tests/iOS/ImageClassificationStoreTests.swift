import XCTest
@testable import Orvian

@MainActor
final class ImageClassificationStoreTests: XCTestCase {
    private func image(modified: Double? = 1) throws -> DriveFile {
        let json = "{\"id\":8,\"name\":\"photo.jpg\",\"type\":\"file\",\"extension_type\":\"image\",\"size\":10\(modified.map { ",\"last_modified_at\":\($0)" } ?? "")}"
        return try JSONDecoder().decode(DriveFile.self, from: Data(json.utf8))
    }

    func testPersistenceIsScopedByAccountDriveRevisionAndModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var account = "account-a"
        let file = try image()
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { account })
        await store.load(credentialFingerprint: account)
        try await store.record(score: 0.9, file: file, driveId: 1, credentialFingerprint: account, modelVersion: NSFWClassifier.modelVersion)
        try await store.flush()
        let restored = ImageClassificationStore(directory: directory, defaults: nil, credential: { account })
        await restored.load(credentialFingerprint: account)
        XCTAssertEqual(restored.score(driveId: 1, file: file), 0.9)
        XCTAssertNil(restored.score(driveId: 2, file: file))
        XCTAssertNil(restored.score(driveId: 1, file: try image(modified: 2)))
        XCTAssertNil(restored.score(driveId: 1, file: try image(modified: nil)))
        account = "account-b"
        XCTAssertNil(restored.score(driveId: 1, file: file))
        restored.resetSession()
        await restored.load(credentialFingerprint: account)
        XCTAssertNil(restored.score(driveId: 1, file: file))
    }

    func testThresholdReclassifiesWithoutChangingScores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        let file = try image()
        await store.load(credentialFingerprint: "account")
        try await store.record(score: 0.85, file: file, driveId: 1, credentialFingerprint: "account", modelVersion: NSFWClassifier.modelVersion)
        let version = store.revision
        store.threshold = 0.90
        XCTAssertGreaterThan(store.revision, version)
        XCTAssertEqual(store.snapshot(driveId: 1, items: [file]).classification(for: file.id, threshold: store.threshold), .sfw)
        XCTAssertEqual(store.score(driveId: 1, file: file), 0.85)
        try await store.flush()
    }

    func testInvalidScoresAreRejected() async throws {
        let store = ImageClassificationStore(defaults: nil, credential: { "account" })
        await store.load(credentialFingerprint: "account")
        for invalid in [Float.nan, .infinity, -1, 2] {
            do {
                try await store.record(score: invalid, file: image(), driveId: 1, credentialFingerprint: "account", modelVersion: NSFWClassifier.modelVersion)
                XCTFail("Invalid score accepted")
            } catch { }
        }
    }

    func testVisibleItemsCacheInvalidatesOnScoreAndThreshold() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        await store.load(credentialFingerprint: "account")
        let file = try image()
        var filters = FileFilters()
        filters.classification = .nsfw
        var cache = VisibleItemsCache()
        func key() -> VisibleItemsKey {
            VisibleItemsKey(source: .directory(1), driveId: 1, itemsRevision: 0, filters: filters,
                searchText: "", metadataRevision: 0, classificationRevision: store.revision, foldersFirst: false)
        }
        XCTAssertTrue(cache.visibleItems(key: key(), items: [file], mediaMetadata: .shared, classificationStore: store).isEmpty)
        try await store.record(score: 0.85, file: file, driveId: 1, credentialFingerprint: "account", modelVersion: NSFWClassifier.modelVersion)
        XCTAssertEqual(cache.visibleItems(key: key(), items: [file], mediaMetadata: .shared, classificationStore: store).map(\.id), [8])
        store.threshold = 0.9
        XCTAssertTrue(cache.visibleItems(key: key(), items: [file], mediaMetadata: .shared, classificationStore: store).isEmpty)
        try await store.flush()
    }

    func testModelChangeAndCorruptCacheDoNotProduceClassification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        let file = try image()
        await store.load(credentialFingerprint: "account")
        try await store.record(score: 0.9, file: file, driveId: 1, credentialFingerprint: "account", modelVersion: "obsolete-model")
        XCTAssertNil(store.score(driveId: 1, file: file))
        try await store.flush()
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries { try Data("not-json".utf8).write(to: entry) }
        let restored = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        await restored.load(credentialFingerprint: "account")
        XCTAssertNil(restored.score(driveId: 1, file: file))
    }
}
