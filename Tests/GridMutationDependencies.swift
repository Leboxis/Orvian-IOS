// Only dependencies are fake; the helper compiles the production view-model methods.
import Foundation

struct DriveFile: Equatable {
    let id: Int
    var name = "old"
    var isFavorite: Bool? = false
    var color: String? = "old"
    var categories: [FileCategory]?
    var parentId: Int? = 1
    var path: String? = "old/path"
    var isDirectory = false
    var addedAt: Double?
    var lastModifiedAt: Double?
    var updatedAt: Double?
}
struct Category { let id: Int }
struct FileCategory: Equatable { let categoryId: Int }
enum FileSource: Equatable {
    case directory(Int), recents, favorites, trash, category(Int)
    case search(String, Int?)
}
struct FileFilters {
    var serverOrderBy: [String]? = nil
    var serverOrder: String = "asc"
}
enum TokenStore {
    static var value: String? = "account-a"
    static func credentialFingerprint() -> String? { value }
}
struct Page {
    var data: [DriveFile]?
    var cursor: String? = nil
    var hasMore: Bool? = false
}
@MainActor final class CallbackServer {
    static let shared = CallbackServer()
    var pages: [CheckedContinuation<Page, Error>] = []
    var counts: [CheckedContinuation<Int, Error>] = []
    var writes: [CheckedContinuation<Void, Error>] = []
    var recentLoads = 0
    var requestedPages: [(cursor: String?, orderBy: [String]?, order: String)] = []
    func page() async throws -> Page {
        try await withCheckedThrowingContinuation { pages.append($0) }
    }
    func count() async throws -> Int {
        try await withCheckedThrowingContinuation { counts.append($0) }
    }
    func write() async throws {
        try await withCheckedThrowingContinuation { writes.append($0) }
    }
    func finishPage(_ data: [DriveFile], cursor: String? = nil, hasMore: Bool = false) {
        pages.removeFirst().resume(returning: Page(data: data, cursor: cursor, hasMore: hasMore))
    }
    func finishCount(_ value: Int) { counts.removeFirst().resume(returning: value) }
    func finishWrite() { writes.removeFirst().resume() }
    func failPage() { pages.removeFirst().resume(throwing: FakeFailure.failed) }
    func failWrite() { writes.removeFirst().resume(throwing: FakeFailure.failed) }
}
enum FakeFailure: Error { case failed }
@MainActor struct KDriveService {
    func page(_ source: FileSource, driveId: Int, cursor: String?, orderBy: [String]?,
              order: String, forceNetwork: Bool = false) async throws -> Page {
        CallbackServer.shared.requestedPages.append((cursor, orderBy, order))
        return try await CallbackServer.shared.page()
    }
    func directoryCount(driveId: Int, directoryId: Int) async throws -> Int {
        try await CallbackServer.shared.count()
    }
    func trash(driveId: Int, fileId: Int, credentialFingerprint: String?) async throws {
        try await CallbackServer.shared.write()
    }
    func setFavorite(driveId: Int, fileId: Int, favorite: Bool,
                     credentialFingerprint: String?) async throws { try await CallbackServer.shared.write() }
    func rename(driveId: Int, fileId: Int, name: String,
                credentialFingerprint: String?) async throws { try await CallbackServer.shared.write() }
    func setFolderColor(driveId: Int, fileId: Int, color: String,
                        credentialFingerprint: String?) async throws { try await CallbackServer.shared.write() }
}
struct RecentSnapshot {
    let items: [DriveFile]
    let cursor: String?
    let hasMore: Bool
    let fetchedAt: Date
}
@MainActor final class RecentUploadsLoader {
    static let shared = RecentUploadsLoader()
    static let source = FileSource.recents
    func refresh(driveId: Int, forceNetwork: Bool = false) async -> RecentSnapshot? {
        CallbackServer.shared.recentLoads += 1
        guard let page = try? await CallbackServer.shared.page() else { return nil }
        return RecentSnapshot(items: page.data ?? [], cursor: page.cursor,
                              hasMore: page.hasMore ?? false, fetchedAt: Date())
    }
}
@MainActor final class CategoryLibrary {
    static let shared = CategoryLibrary()
    func ensureLoaded(for driveId: Int) async {}
}
@MainActor final class DirectoryListStore {
    static let shared = DirectoryListStore()
    func mergeRecentUploads(driveId: Int, files: [DriveFile]) {}
}
@MainActor final class FileGridMutationCenter {
    static let shared = FileGridMutationCenter()
    // Deliberately no self-echo: originating confirmations must work without a view.
    func publish(_ mutation: FileGridMutation, credentialFingerprint: String?) {}
}
