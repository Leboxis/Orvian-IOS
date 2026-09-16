"""Exercise production concurrency/cache helpers on the existing macOS runner."""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(output, sources):
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                    "-target", f"{platform.machine()}-apple-macosx14.0",
                    *map(str, sources), "-o", str(output)], check=True)
    subprocess.run([str(output)], check=True, timeout=60)


with tempfile.TemporaryDirectory() as temporary:
    temp = Path(temporary)
    combined = temp / "ConcurrencyChecks.swift"
    combined.write_text(
        (ROOT / "Orvian/Core/Network/SharedRequests.swift").read_text(encoding="utf-8")
        + "\n" + (ROOT / "Tests/ConcurrencyChecks.swift").read_text(encoding="utf-8"), encoding="utf-8")
    run(temp / "concurrency", [combined, *[ROOT / path for path in [
        "Orvian/Core/Utils/BoundedConcurrency.swift", "Orvian/Core/Cache/DiskDirectory.swift",
        "Orvian/Core/API/ResponseDecoder.swift", "Orvian/Core/API/APIError.swift",
    ]]])
    media = temp / "MediaChecks.swift"
    media.write_text('''import Foundation
actor URLCalls {
    static let shared = URLCalls()
    var count = 0
    func next() -> Int { count += 1; return count }
}
struct KDriveService {
    func temporaryURL(driveId: Int, fileId: Int) async throws -> URL {
        let count = await URLCalls.shared.next()
        return URL(string: "https://example.invalid/\\(fileId)/\\(count)")!
    }
}
enum TokenStore { static func credentialFingerprint() -> String? { "account-a" } }
''' + (ROOT / "Orvian/Core/Media/MediaURLCache.swift").read_text(encoding="utf-8")
        + "\n" + (ROOT / "Tests/MediaURLCacheChecks.swift").read_text(encoding="utf-8"), encoding="utf-8")
    run(temp / "media", [media])

    recent = temp / "RecentLoaderChecks.swift"
    recent.write_text('''import Foundation
struct DriveFile {
    let id: Int
    var isDirectory: Bool { false }
    var updatedAt: Double? { nil }
    var lastModifiedAt: Double? { nil }
    var addedAt: Double? { nil }
}
enum FileSource { case recents(limit: Int) }
struct DirectoryListSnapshot {
    var items: [DriveFile]
    var cursor: String?
    var hasMore: Bool
    var totalItemCount: Int?
    var orderBy: [String]
    var order: String
    var fetchedAt: Date = .distantPast
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
@MainActor final class FakeServer {
    static let shared = FakeServer()
    var requests: [Bool] = []
    var pending: [Int: CheckedContinuation<FakePage, Never>] = [:]
    func page(force: Bool) async -> FakePage {
        let index = requests.count
        requests.append(force)
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, fileID: Int) {
        pending.removeValue(forKey: index)!.resume(returning: FakePage(data: [DriveFile(id: fileID)]))
    }
}
struct KDriveService {
    func page(_ source: FileSource, driveId: Int, cursor: String?, forceNetwork: Bool) async throws -> FakePage {
        await FakeServer.shared.page(force: forceNetwork)
    }
}
@MainActor final class DirectoryListStore {
    static let shared = DirectoryListStore()
    var saved: DirectoryListSnapshot?
    func snapshot(source: FileSource, driveId: Int, orderBy: [String], order: String) -> DirectoryListSnapshot? { saved }
    func diskSnapshot(source: FileSource, driveId: Int, orderBy: [String], order: String) async -> DirectoryListSnapshot? { nil }
    func store(source: FileSource, driveId: Int, orderBy: [String], order: String, items: [DriveFile], cursor: String?, hasMore: Bool, totalItemCount: Int?, fetchedAt: Date) {
        saved = DirectoryListSnapshot(items: items, cursor: cursor, hasMore: hasMore, totalItemCount: totalItemCount,
                                      orderBy: orderBy, order: order, fetchedAt: fetchedAt)
    }
}
''' + (ROOT / "Orvian/Core/Cache/RecentUploadsLoader.swift").read_text(encoding="utf-8")
        + "\n" + (ROOT / "Tests/RecentLoaderChecks.swift").read_text(encoding="utf-8"), encoding="utf-8")
    run(temp / "recent", [recent])
