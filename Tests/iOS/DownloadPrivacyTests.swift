import XCTest
import UIKit
@testable import Orvian

@MainActor
final class DownloadPrivacyTests: XCTestCase {
    private func completedFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("private.txt")
        try Data("Private download".utf8).write(to: file)
        return (directory, file)
    }

    func testLockedDownloadWaitsAndUsesContentWindowInsteadOfKeyWindow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.keyWindow
        let owner = UIWindow(windowScene: scene)
        let content = UIViewController()
        owner.rootViewController = content
        owner.makeKeyAndVisible()
        let shield = UIWindow(windowScene: scene)
        let lock = UIViewController()
        shield.rootViewController = lock
        shield.windowLevel = .alert + 1
        shield.makeKeyAndVisible()
        let service = FileDownloadService(currentCredential: { "account-a" })
        let payload = try completedFile()
        defer {
            service.cancelAllAndClear()
            shield.isHidden = true
            owner.isHidden = true
            original?.makeKey()
            try? FileManager.default.removeItem(at: payload.directory)
        }
        service.updatePresentation(isAllowed: false, window: owner)
        service.enqueueCompletedDownload(fileURL: payload.file, directory: payload.directory, credential: "account-a")
        XCTAssertNil(lock.presentedViewController)
        XCTAssertNil(content.presentedViewController)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.file.path))

        // Même si la fenêtre clé est encore le verrou, le présentateur doit
        // être la fenêtre de contenu explicitement autorisée.
        service.updatePresentation(isAllowed: true, window: owner)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(lock.presentedViewController)
        XCTAssertTrue(content.presentedViewController is UIActivityViewController)
    }

    func testLogoutRemovesDeferredFileBeforeAnyLaterUnlock() throws {
        let service = FileDownloadService(currentCredential: { "account-a" })
        let payload = try completedFile()
        defer { try? FileManager.default.removeItem(at: payload.directory) }
        service.enqueueCompletedDownload(fileURL: payload.file, directory: payload.directory, credential: "account-a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.file.path))
        service.cancelAllAndClear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.directory.path))
        XCTAssertNil(service.downloadingFileName)
        XCTAssertFalse(service.isDownloading)
    }

    func testCredentialChangeDiscardsDeferredFile() throws {
        var credential = "account-a"
        let service = FileDownloadService(currentCredential: { credential })
        let payload = try completedFile()
        defer { service.cancelAllAndClear() }
        service.enqueueCompletedDownload(fileURL: payload.file, directory: payload.directory, credential: credential)
        credential = "account-b"
        service.updatePresentation(isAllowed: true, window: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.directory.path))
    }
}
