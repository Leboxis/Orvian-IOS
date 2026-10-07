import XCTest
@testable import Orvian

@MainActor
final class FolderImageScannerTests: XCTestCase {
    private var directories: [URL] = []

    override nonisolated func tearDown() async throws {
        await MainActor.run {
            for directory in self.directories { try? FileManager.default.removeItem(at: directory) }
            self.directories = []
        }
        try await super.tearDown()
    }

    private func makeStore(credential: @escaping () -> String?) -> ImageClassificationStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return ImageClassificationStore(directory: directory, defaults: nil, credential: credential)
    }
    private func file(_ id: Int, kind: String = "image", modified: Int? = 1) throws -> DriveFile {
        let json = "{\"id\":\(id),\"name\":\"item\",\"type\":\"\(kind == "dir" ? "dir" : "file")\",\"extension_type\":\"\(kind)\"\(modified.map { ",\"last_modified_at\":\($0)" } ?? "")}"
        return try JSONDecoder().decode(DriveFile.self, from: Data(json.utf8))
    }

    func testScansOnlyDirectImagesAcrossEveryPageAndReusesScores() async throws {
        let images = try [file(1), file(2)]
        let folder = try file(99, kind: "dir")
        let directory = try file(70, kind: "dir")
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ImageClassificationStore(directory: directoryURL, defaults: nil, credential: { "account" })
        var requests: [Int] = []
        var classified = 0
        let scanner = FolderImageScanner(store: store, credential: { "account" },
            page: { _, id, cursor in
                requests.append(id)
                switch cursor {
                case nil: return CursorPage(data: [images[0], folder], cursor: "a", hasMore: true)
                case "a": return CursorPage(data: [folder], cursor: "b", hasMore: true)
                default: return CursorPage(data: [images[0], images[1]], hasMore: false)
                }
            }, imageData: { _, _ in Data() }, prepare: {}, classify: { _ in classified += 1; return ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7) })
        scanner.start(driveId: 3, directory: directory)
        await scanner.task?.value
        XCTAssertEqual(requests, [70, 70, 70])
        XCTAssertEqual(classified, 2)
        XCTAssertEqual(scanner.progress?.total, 2)
        XCTAssertEqual(scanner.progress?.processed, 2)
        XCTAssertEqual(scanner.progress?.phase, .completed)
        scanner.start(driveId: 3, directory: directory)
        await scanner.task?.value
        XCTAssertEqual(classified, 2)
        XCTAssertEqual(scanner.progress?.reused, 2)
    }

    func testRepeatedCursorFailsInsteadOfReportingSuccess() async throws {
        let scanner = FolderImageScanner(credential: { "account" },
            page: { _, _, _ in CursorPage(data: [], cursor: "same", hasMore: true) },
            imageData: { _, _ in Data() }, prepare: {}, classify: { _ in ImageContentScores(nudity: 0.1, semen: 0.2, feet: 0.7) })
        scanner.start(driveId: 1, directory: try file(70, kind: "dir"))
        await scanner.task?.value
        XCTAssertEqual(scanner.progress?.phase, .failed)
        XCTAssertNotNil(scanner.progress?.errorMessage)
    }

    func testThreeCategoryCountsAndInvalidModelResultRemainConsistent() async throws {
        let images = try (1...5).map { try file($0) }
        let store = makeStore(credential: { "account" })
        let results: [ImageContentScores] = [
            .init(nudity: 0.6, semen: 0.1, feet: 0.95),
            .init(nudity: 0.1, semen: 0.8, feet: 0.1),
            .init(nudity: 0.1, semen: 0.1, feet: 0.8),
            .init(nudity: 0.1, semen: 0.1, feet: 0.1),
            .init(nudity: 0.1, semen: .nan, feet: 0.1)
        ]
        let scanner = FolderImageScanner(store: store, credential: { "account" },
            page: { _, _, _ in CursorPage(data: images, hasMore: false) },
            imageData: { _, id in Data([UInt8(id - 1)]) }, prepare: {},
            classify: { results[Int($0[0])] })
        scanner.start(driveId: 1, directory: try file(70, kind: "dir"))
        await scanner.task?.value
        XCTAssertEqual(scanner.progress?.phase, .completed)
        XCTAssertEqual(scanner.progress?.failed, 1)
        XCTAssertEqual(scanner.nsfwCount, 2)
        XCTAssertEqual(scanner.feetCount, 1)
        XCTAssertEqual(scanner.sfwCount, 1)
        XCTAssertNil(store.scores(driveId: 1, file: images[4]))
        store.threshold = 0.9
        XCTAssertEqual(scanner.nsfwCount, 0)
        XCTAssertEqual(scanner.feetCount, 1)
        XCTAssertEqual(scanner.sfwCount, 3)
    }

    func testPageFailureIsNotSuccess() async throws {
        let scanner = FolderImageScanner(credential: { "account" },
            page: { _, _, _ in throw ClassificationError.invalidPagination },
            imageData: { _, _ in Data() }, prepare: {}, classify: { _ in ImageContentScores(nudity: 0.1, semen: 0.2, feet: 0.7) })
        scanner.start(driveId: 1, directory: try file(70, kind: "dir"))
        await scanner.task?.value
        XCTAssertEqual(scanner.progress?.phase, .failed)
    }

    func testImageFailureContinuesAndEmptyFolderCompletes() async throws {
        let images = try [file(1), file(2)]
        var empty = false
        let store = makeStore(credential: { "account" })
        let scanner = FolderImageScanner(store: store, credential: { "account" },
            page: { _, _, _ in CursorPage(data: empty ? [] : images, hasMore: false) },
            imageData: { _, id in if id == 1 { throw ClassificationError.invalidImage }; return Data() },
            prepare: {}, classify: { _ in ImageContentScores(nudity: 0.1, semen: 0.2, feet: 0.7) })
        scanner.start(driveId: 1, directory: try file(70, kind: "dir"))
        await scanner.task?.value
        XCTAssertEqual(scanner.progress?.failed, 1)
        XCTAssertEqual(scanner.progress?.processed, 2)
        XCTAssertNil(store.scores(driveId: 1, file: images[0]))
        empty = true
        scanner.start(driveId: 1, directory: try file(70, kind: "dir"))
        await scanner.task?.value
        XCTAssertEqual(scanner.progress?.total, 0)
        XCTAssertEqual(scanner.progress?.phase, .completed)
    }

    func testCancellationRejectsLateResultsAndSecondStartDoesNotDuplicate() async throws {
        try await checkLateResult(changeAccount: false)
    }

    func testAccountChangeRejectsLateResults() async throws {
        try await checkLateResult(changeAccount: true)
    }

    func testRescanReanalyzesTimestampUnknownImage() async throws {
        let image = try file(1, modified: nil)
        let folder = try file(70, kind: "dir")
        let store = makeStore(credential: { "account" })
        var calls = 0
        let scanner = FolderImageScanner(store: store, credential: { "account" },
            page: { _, _, _ in CursorPage(data: [image], hasMore: false) },
            imageData: { _, _ in Data() }, prepare: {}, classify: { _ in calls += 1; return ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7) })
        scanner.start(driveId: 1, directory: folder)
        await scanner.task?.value
        XCTAssertEqual(store.scores(driveId: 1, file: image), ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7))
        scanner.start(driveId: 1, directory: folder)
        await scanner.task?.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(scanner.progress?.reused, 0)
    }

    private func checkLateResult(changeAccount: Bool) async throws {
        let image = try file(1)
        let folder = try file(70, kind: "dir")
        var account = "account"
        let store = makeStore(credential: { account })
        var continuation: CheckedContinuation<ImageContentScores, Never>?
        var calls = 0
        let started = expectation(description: "classification started")
        let scanner = FolderImageScanner(store: store, credential: { account },
            page: { _, _, _ in CursorPage(data: [image], hasMore: false) },
            imageData: { _, _ in Data() }, prepare: {}, classify: { _ in
                calls += 1
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
        scanner.start(driveId: 1, directory: folder)
        let running = scanner.task
        await fulfillment(of: [started], timeout: 5)
        scanner.start(driveId: 1, directory: folder)
        XCTAssertEqual(calls, 1)
        if changeAccount { account = "other" } else { scanner.cancel() }
        continuation?.resume(returning: ImageContentScores(nudity: 0.9, semen: 0.2, feet: 0.7))
        await running?.value
        XCTAssertNil(store.scores(driveId: 1, file: image))
        XCTAssertEqual(scanner.progress?.phase, .cancelled)
    }
}
