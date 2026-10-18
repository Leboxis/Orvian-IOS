"""Exercise production thumbnail and grid scheduling without rendering any UI."""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def run(directory, name, code):
    path = directory / (name + ".swift")
    path.write_text(code, encoding="utf-8")
    output = directory / name
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                    "-target", f"{platform.machine()}-apple-macosx14.0",
                    str(path), "-o", str(output)], check=True, timeout=60)
    subprocess.run([str(output)], check=True, timeout=60)


with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    # Replace UIKit and disk/network dependencies, retaining the complete
    # production provider, request sharing, throttler and failure policy.
    thumbnail_dependencies = '''import Foundation
final class UIImage: @unchecked Sendable {
    let size = CGSize(width: 1, height: 1)
    init?(data: Data) { if data.isEmpty { return nil } }
    func preparingForDisplay() -> UIImage? { self }
}
enum TokenStore { static func credentialFingerprint() -> String? { "account-a" } }
struct KDriveService {
    func thumbnailData(driveId: Int, fileId: Int, isTrashed: Bool) async throws -> Data {
        try await ThumbnailTestServer.shared.data(fileId: fileId)
    }
}
final class DiskImageCache: @unchecked Sendable {
    struct ThumbnailInformation {}
    func hasEntry(credentialFingerprint: String, driveId: Int, fileId: Int, isTrashed: Bool) -> Bool { false }
    func loadImage(credentialFingerprint: String, driveId: Int, fileId: Int, isTrashed: Bool) -> UIImage? { nil }
    func store(data: Data, credentialFingerprint: String, driveId: Int, fileId: Int, isTrashed: Bool) {}
    func removeEntry(credentialFingerprint: String, driveId: Int, fileId: Int, isTrashed: Bool) {}
    func thumbnailInformation(credentialFingerprint: String, driveId: Int) -> [ThumbnailInformation] { [] }
    func purge() {}
    func totalSize() -> Int { 0 }
    func enforceSizeLimit() {}
}
'''
    run(directory, "thumbnails", thumbnail_dependencies + "\n" + "\n".join(source(path) for path in [
        "Orvian/Core/Network/SharedRequests.swift", "Orvian/Core/Cache/AsyncThrottler.swift",
        "Orvian/Core/Cache/ThumbnailFailureLedger.swift", "Orvian/Core/API/APIError.swift",
    ]) + "\n" + source("Orvian/Core/Cache/ThumbnailProvider.swift").replace("import UIKit", "")
        + "\n" + source("Tests/ThumbnailPipelineChecks.swift"))

    grid = source("Orvian/Features/Shared/FileGridView.swift")
    # Substitute only the 180 ms sleep with a manually released delay. The
    # actual appeared/worker methods choose the request, window and policies.
    worker = grid[grid.index("    private func appeared("):grid.index("    // MARK: - États")]
    worker = worker.replace("try await Task.sleep(for: .milliseconds(180))",
                            "try await PrefetchDelay.shared.wait()")
    grid_dependencies = '''import Foundation
struct DriveFile {
    let id: Int
    struct Kind { let supportsThumbnail = true }
    var fileKind: Kind { Kind() }
    var isVideo: Bool { false }
}
enum FileSource { case directory, trash }
struct FileGridViewModel { var driveId = 1; var source = FileSource.directory }
enum FilePresentation { case grid, list }
@MainActor final class NetworkMonitor {
    static let shared = NetworkMonitor()
    var allowsBackgroundPrefetch = true
}
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()
    var requests: [[Int]] = []
    func prefetch(driveId: Int, fileIds: [Int], isTrashed: Bool) { requests.append(fileIds) }
}
actor VideoAssetCache {
    static let shared = VideoAssetCache()
    func prefetch(driveId: Int, fileIds: [Int]) {}
}
@MainActor final class FileGridView {
    var viewModel = FileGridViewModel()
    var columns = [0, 0, 0]
    var presentation = FilePresentation.grid
    var prefetchThumbnails = true
    var prefetchVideoURLs = true
    var prefetchOnWiFiOnly = true
    private var pendingPrefetch: PrefetchRequest?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchRequestID: UUID?
    func requestMoreFiles() {}
'''
    run(directory, "prefetch", grid_dependencies + worker + "\n}\n"
        + source("Tests/IPadPrefetchChecks.swift"))
