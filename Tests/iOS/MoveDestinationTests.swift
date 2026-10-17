import XCTest
@testable import Orvian

@MainActor
final class MoveDestinationTests: XCTestCase {
    private func item(_ id: Int, parent: Int? = nil, directory: Bool = true) throws -> DriveFile {
        var json: [String: Any] = ["id": id, "name": "Item \(id)", "type": directory ? "dir" : "file"]
        if let parent { json["parent_id"] = parent }
        return try JSONDecoder().decode(DriveFile.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testKnownOriginAndRepeatedUpStopOnlyAtDriveRoot() async throws {
        let start = try item(6, parent: 5)
        var requests: [Int] = []
        let model = MoveDestinationModel(files: [try item(100, parent: 6, directory: false)], initialDirectory: start,
            credential: "a", currentCredential: { "a" }, loadDirectory: { id in
                requests.append(id)
                return try self.item(id, parent: id - 1)
            }, createDirectory: { _, _ in })
        await model.loadStart()
        XCTAssertTrue(requests.isEmpty, "A known source folder must appear without a metadata request")
        for expected in stride(from: 5, through: 1, by: -1) {
            await model.goUp()
            XCTAssertEqual(model.directory?.id, expected)
        }
        XCTAssertFalse(model.canGoUp)
        await model.goUp()
        XCTAssertEqual(model.directory?.id, 1)
        XCTAssertEqual(requests, [5, 4, 3, 2])
    }

    func testMissingParentIsResolvedBeforeOpeningTheActualOrigin() async throws {
        var requests: [Int] = []
        let model = MoveDestinationModel(files: [try item(100, directory: false)], initialDirectory: nil,
            credential: "a", currentCredential: { "a" }, loadDirectory: { id in
                requests.append(id)
                return try self.item(id, parent: id == 100 ? 20 : 10, directory: id != 100)
            }, createDirectory: { _, _ in })
        await model.loadStart()
        XCTAssertEqual(model.directory?.id, 20)
        XCTAssertEqual(requests, [100, 20])
    }

    func testSearchResultParentOverridesTheVisibleBrowserFolder() async throws {
        let model = MoveDestinationModel(files: [try item(100, parent: 20, directory: false)],
            initialDirectory: try item(30, parent: 1), credential: "a", currentCredential: { "a" },
            loadDirectory: { try self.item($0, parent: 1) }, createDirectory: { _, _ in })
        await model.loadStart()
        XCTAssertEqual(model.directory?.id, 20)
    }

    func testMixedOriginCannotMoveAnAncestorIntoItsOwnDescendant() async throws {
        let model = MoveDestinationModel(files: [try item(100, parent: 20, directory: false), try item(10, parent: 1)],
            initialDirectory: try item(20, parent: 10), credential: "a", currentCredential: { "a" },
            loadDirectory: { try self.item($0, parent: 1) }, createDirectory: { _, _ in })
        let invalid = await model.confirmedDestination()
        XCTAssertNil(invalid)
        XCTAssertNotNil(model.error)
        await model.goUp()
        await model.goUp()
        let root = await model.confirmedDestination()
        XCTAssertEqual(root?.id, 1)
    }

    func testCreationTargetsTheCurrentlyBrowsedFolderAndReloadsOnce() async throws {
        var created: [(Int, String)] = []
        let model = MoveDestinationModel(files: [], initialDirectory: try item(20, parent: 10),
            credential: "a", currentCredential: { "a" }, loadDirectory: { try self.item($0, parent: 1) },
            createDirectory: { created.append(($0, $1)) })
        model.open(try item(21, parent: 20))
        let success = await model.createFolder(name: "  Nouveau  ")
        XCTAssertTrue(success)
        XCTAssertEqual(created.map(\.0), [21])
        XCTAssertEqual(created.map(\.1), ["Nouveau"])
        XCTAssertEqual(model.reloadRevision, 1)
        let empty = await model.createFolder(name: " \n ")
        XCTAssertFalse(empty)
        XCTAssertEqual(created.count, 1)
    }

    func testFailedParentLookupKeepsCurrentFolderAndAllowsRetry() async throws {
        var fails = true
        let model = MoveDestinationModel(files: [], initialDirectory: try item(20, parent: 10),
            credential: "a", currentCredential: { "a" }, loadDirectory: { id in
                if fails { throw URLError(.notConnectedToInternet) }
                return try self.item(id, parent: 1)
            }, createDirectory: { _, _ in })
        await model.goUp()
        XCTAssertEqual(model.directory?.id, 20)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isBusy)
        fails = false
        await model.goUp()
        XCTAssertEqual(model.directory?.id, 10)
        XCTAssertNil(model.error)
    }

    func testBusyCreationBlocksNavigationAndAccountChangeDiscardsItsResult() async throws {
        var credential = "a"
        var pending: CheckedContinuation<Void, Error>?
        var requests = 0
        let model = MoveDestinationModel(files: [], initialDirectory: try item(20, parent: 10),
            credential: "a", currentCredential: { credential }, loadDirectory: { try self.item($0, parent: 1) },
            createDirectory: { _, _ in
                requests += 1
                try await withCheckedThrowingContinuation { pending = $0 }
            })
        let task = Task { await model.createFolder(name: "Dossier") }
        for _ in 0..<100 {
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completion = try XCTUnwrap(pending)
        XCTAssertTrue(model.isBusy)
        model.open(try item(30, parent: 1))
        await model.goUp()
        let duplicate = await model.createFolder(name: "Autre")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.directory?.id, 20)
        credential = "b"
        completion.resume()
        let success = await task.value
        XCTAssertFalse(success)
        XCTAssertEqual(model.reloadRevision, 0)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.isBusy)
        let wrongAccount = await model.createFolder(name: "Interdit")
        XCTAssertFalse(wrongAccount)
        XCTAssertEqual(requests, 1)
    }
}
