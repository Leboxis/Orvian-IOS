import Foundation

struct DriveFile {
    let id: Int
    var isDirectory = false
}
enum FileSource: Hashable { case recents(limit: Int) }
struct DirectoryListSnapshot {
    var items: [DriveFile]
    var cursor: String?
    var hasMore: Bool
    var totalItemCount: Int?
    var orderBy: [String]
    var order: String
    var fetchedAt: Date
}
struct FakePage {
    var data: [DriveFile]?
    var cursor: String? = nil
    var hasMore: Bool? = false
}
@MainActor enum TokenStore {
    static var value = "account-a"
    static func credentialFingerprint() -> String? { value }
}
@MainActor final class FileGridMutationCenter {
    static let shared = FileGridMutationCenter()
    var removedIDs: Set<Int> = []
    var recordedAt = Date.distantPast
    func isSnapshotStale(_ snapshot: DirectoryListSnapshot, source: FileSource, driveId: Int) -> Bool {
        snapshot.fetchedAt < recordedAt && snapshot.items.contains { removedIDs.contains($0.id) }
    }
}
@MainActor final class FakeServer {
    static let shared = FakeServer()
    var drives: [Int] = []
    var pending: [Int: CheckedContinuation<FakePage, Never>] = [:]
    func page(driveId: Int) async -> FakePage {
        let index = drives.count
        drives.append(driveId)
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, fileID: Int) {
        pending.removeValue(forKey: index)!.resume(returning: FakePage(data: [DriveFile(id: fileID)]))
    }
}
struct KDriveService {
    func page(_ source: FileSource, driveId: Int, cursor: String?, forceNetwork: Bool) async throws -> FakePage {
        precondition(cursor == nil, "The preview must never paginate to fill three cards")
        return await FakeServer.shared.page(driveId: driveId)
    }
}
@MainActor final class DirectoryListStore {
    static let shared = DirectoryListStore()
    var entries: [String: DirectoryListSnapshot] = [:]
    var pendingDisk: CheckedContinuation<DirectoryListSnapshot?, Never>?
    var diskReadCount = 0
    var suspendDisk = false
    func key(_ driveId: Int, orderBy: [String] = [], order: String = "asc") -> String {
        "\(TokenStore.value)|\(driveId)|\(orderBy.joined(separator: ","))|\(order)"
    }
    func snapshot(source: FileSource, driveId: Int, orderBy: [String], order: String) -> DirectoryListSnapshot? {
        entries[key(driveId, orderBy: orderBy, order: order)]
    }
    func diskSnapshot(source: FileSource, driveId: Int, orderBy: [String], order: String) async -> DirectoryListSnapshot? {
        diskReadCount += 1
        guard suspendDisk else { return nil }
        return await withCheckedContinuation { pendingDisk = $0 }
    }
    func finishDisk(_ snapshot: DirectoryListSnapshot?) {
        let continuation = pendingDisk!
        pendingDisk = nil
        continuation.resume(returning: snapshot)
    }
    func store(source: FileSource, driveId: Int, orderBy: [String], order: String, items: [DriveFile], cursor: String?, hasMore: Bool, totalItemCount: Int?, fetchedAt: Date) {
        entries[key(driveId, orderBy: orderBy, order: order)] = DirectoryListSnapshot(items: items, cursor: cursor, hasMore: hasMore,
            totalItemCount: totalItemCount, orderBy: orderBy, order: order, fetchedAt: fetchedAt)
    }
}
