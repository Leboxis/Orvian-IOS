import Foundation

struct FileCategory: Equatable { let categoryId: Int }
struct Category { let id: Int }
struct DriveFile: Equatable {
    let id: Int
    var name: String = "Known name"
    var path: String?
    var categories: [FileCategory]?
    var size: Int?
    var isDirectory = false
}
@MainActor enum TokenStore {
    static var value: String? = "a"
    static func credentialFingerprint() -> String? { value }
}
@MainActor final class CategoryLibrary {
    static let shared = CategoryLibrary()
    var loaded = true
    var pending: CheckedContinuation<Void, Error>?
    func hasLoaded(for driveId: Int) -> Bool { loaded }
    func requireLoaded(for driveId: Int) async throws {
        if !loaded { try await withCheckedThrowingContinuation { pending = $0 } }
    }
    func finish() {
        loaded = true
        pending?.resume()
        pending = nil
    }
    func categories(for driveId: Int) -> [Int: Category] { loaded ? [1: Category(id: 1)] : [:] }
}
@MainActor final class DetailsServer {
    static let shared = DetailsServer()
    var pending: [CheckedContinuation<DriveFile, Error>?] = []
    func request() async throws -> DriveFile {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ index: Int, file: DriveFile) { pending[index]!.resume(returning: file); pending[index] = nil }
    func fail(_ index: Int) { pending[index]!.resume(throwing: URLError(.notConnectedToInternet)); pending[index] = nil }
}
@MainActor final class FolderSizeServer {
    static let shared = FolderSizeServer()
    var pending: [CheckedContinuation<Int, Error>?] = []
    var credentials: [String] = []
    func request(credential: String) async throws -> Int {
        credentials.append(credential)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ index: Int, size: Int) { pending[index]!.resume(returning: size); pending[index] = nil }
    func fail(_ index: Int) { pending[index]!.resume(throwing: URLError(.notConnectedToInternet)); pending[index] = nil }
}
struct KDriveService {
    func fileInfo(driveId: Int, fileId: Int) async throws -> DriveFile { try await DetailsServer.shared.request() }
    func directorySize(driveId: Int, directoryId: Int, credentialFingerprint: String) async throws -> Int {
        try await FolderSizeServer.shared.request(credential: credentialFingerprint)
    }
}
