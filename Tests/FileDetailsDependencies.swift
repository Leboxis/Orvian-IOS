import Foundation

struct FileCategory { let categoryId: Int }
struct Category { let id: Int }
struct DriveFile {
    let id: Int
    var name: String = "Known name"
    var path: String?
    var categories: [FileCategory]?
}
@MainActor enum TokenStore {
    static var value: String? = "a"
    static func credentialFingerprint() -> String? { value }
}
@MainActor final class CategoryLibrary {
    static let shared = CategoryLibrary()
    func requireLoaded(for driveId: Int) async throws {}
    func categories(for driveId: Int) -> [Int: Category] { [1: Category(id: 1)] }
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
struct KDriveService {
    func fileInfo(driveId: Int, fileId: Int) async throws -> DriveFile { try await DetailsServer.shared.request() }
}
