import XCTest
@testable import Orvian

@MainActor
final class ImageClassificationStoreTests: XCTestCase {
    private func image(modified: Double? = 1, size: Int = 10) throws -> DriveFile {
        let json = "{\"id\":8,\"name\":\"photo.jpg\",\"type\":\"file\",\"extension_type\":\"image\",\"size\":\(size)\(modified.map { ",\"last_modified_at\":\($0)" } ?? "")}"
        return try JSONDecoder().decode(DriveFile.self, from: Data(json.utf8))
    }

    func testPersistenceIsScopedByAccountDriveRevisionAndModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var account = "account-a"
        let file = try image()
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { account })
        await store.load(credentialFingerprint: account)
        try await store.record(scores: ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7), file: file, driveId: 1, credentialFingerprint: account, modelVersion: NSFWImageClassifier.modelVersion)
        try await store.flush()
        let restored = ImageClassificationStore(directory: directory, defaults: nil, credential: { account })
        await restored.load(credentialFingerprint: account)
        XCTAssertEqual(restored.scores(driveId: 1, file: file), ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7))
        XCTAssertNil(restored.scores(driveId: 2, file: file))
        XCTAssertNil(restored.scores(driveId: 1, file: try image(modified: 2)))
        XCTAssertNil(restored.scores(driveId: 1, file: try image(modified: nil)))
        account = "account-b"
        XCTAssertNil(restored.scores(driveId: 1, file: file))
        restored.resetSession()
        await restored.load(credentialFingerprint: account)
        XCTAssertNil(restored.scores(driveId: 1, file: file))
    }

    func testThresholdReclassifiesWithoutChangingScores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        let file = try image()
        await store.load(credentialFingerprint: "account")
        try await store.record(scores: ImageContentScores(nudity: 0.85, semen: 0.2, feet: 0.7), file: file, driveId: 1, credentialFingerprint: "account", modelVersion: NSFWImageClassifier.modelVersion)
        let version = store.revision
        store.threshold = 0.90
        XCTAssertGreaterThan(store.revision, version)
        XCTAssertEqual(store.snapshot(driveId: 1, items: [file]).classification(for: file.id, threshold: store.threshold), .sfw)
        XCTAssertEqual(store.scores(driveId: 1, file: file), ImageContentScores(nudity: 0.85, semen: 0.2, feet: 0.7))
        try await store.flush()
    }

    func testInvalidScoresAreRejected() async throws {
        let store = ImageClassificationStore(defaults: nil, credential: { "account" })
        await store.load(credentialFingerprint: "account")
        for invalid in [Float.nan, .infinity, -1, 2] {
            for channel in 0..<3 {
                let scores = ImageContentScores(nudity: channel == 0 ? invalid : 0,
                    semen: channel == 1 ? invalid : 0, feet: channel == 2 ? invalid : 0)
                do {
                    try await store.record(scores: scores, file: image(), driveId: 1, credentialFingerprint: "account", modelVersion: NSFWImageClassifier.modelVersion)
                    XCTFail("Invalid score accepted")
                } catch { }
            }
        }
    }

    func testThresholdClampsOnceAndRejectsNonFiniteValues() {
        let store = ImageClassificationStore(defaults: nil, credential: { "account" })
        let initialRevision = store.revision
        store.threshold = 2
        XCTAssertEqual(store.threshold, 0.99)
        XCTAssertEqual(store.revision, initialRevision + 1)
        store.threshold = 2
        XCTAssertEqual(store.revision, initialRevision + 1)
        store.threshold = -1
        XCTAssertEqual(store.threshold, 0.30)
        XCTAssertEqual(store.revision, initialRevision + 2)
        for value in [Float.nan, .infinity, -.infinity] { store.threshold = value }
        XCTAssertEqual(store.threshold, 0.30)
        XCTAssertEqual(store.revision, initialRevision + 2)
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
        try await store.record(scores: ImageContentScores(nudity: 0.85, semen: 0.2, feet: 0.7), file: file, driveId: 1, credentialFingerprint: "account", modelVersion: NSFWImageClassifier.modelVersion)
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
        try await store.record(scores: ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7), file: file, driveId: 1, credentialFingerprint: "account", modelVersion: "obsolete-model")
        XCTAssertNil(store.scores(driveId: 1, file: file))
        try await store.flush()
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries { try Data("not-json".utf8).write(to: entry) }
        let restored = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        await restored.load(credentialFingerprint: "account")
        XCTAssertNil(restored.scores(driveId: 1, file: file))
    }

    func testUnknownRevisionIsSessionOnlyAndSizeChangeInvalidates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        await store.load(credentialFingerprint: "account")
        let original = try image(modified: nil)
        try await store.record(scores: ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7), file: original, driveId: 1, credentialFingerprint: "account", modelVersion: NSFWImageClassifier.modelVersion)
        XCTAssertEqual(store.scores(driveId: 1, file: original), ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7))
        XCTAssertNil(store.scores(driveId: 1, file: try image(modified: nil, size: 20)))
        try await store.flush()
        let restored = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        await restored.load(credentialFingerprint: "account")
        XCTAssertNil(restored.scores(driveId: 1, file: original))
    }

    func testLegacySingleScoreDoesNotBecomeAThreeCategoryResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        let file = try image()
        await store.load(credentialFingerprint: "account")
        try await store.record(scores: .init(nudity: 0.9, semen: 0.2, feet: 0.7), file: file,
            driveId: 1, credentialFingerprint: "account", modelVersion: NSFWImageClassifier.modelVersion)
        try await store.flush()
        let cache = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first)
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: [String: Any]])
        entries["1|8"]?.removeValue(forKey: "semenScore")
        entries["1|8"]?.removeValue(forKey: "feetScore")
        try JSONSerialization.data(withJSONObject: entries).write(to: cache)
        let restored = ImageClassificationStore(directory: directory, defaults: nil, credential: { "account" })
        await restored.load(credentialFingerprint: "account")
        XCTAssertNil(restored.scores(driveId: 1, file: file))
        XCTAssertEqual(restored.snapshot(driveId: 1, items: [file]).classification(for: file.id,
            threshold: restored.threshold), .unscanned)
    }

    func testEmptyPaginationTaskRestartsWhenClassificationChanges() {
        var filters = FileFilters()
        filters.classification = .unscanned
        let grid = FileGridView(viewModel: FileGridViewModel(source: .directory(1), driveId: 1), filters: filters)
        let store = ImageClassificationStore.shared
        let oldThreshold = store.threshold
        defer { store.threshold = oldThreshold }
        let oldKey = grid.emptyFilteredPageTaskKey
        store.threshold = oldThreshold < 0.90 ? 0.90 : 0.80
        XCTAssertNotEqual(grid.emptyFilteredPageTaskKey, oldKey)
    }
}
