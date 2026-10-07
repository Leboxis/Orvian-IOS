"""Execute production restoration, upload permits and page/count ordering."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def run(output, paths):
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                    *map(str, paths), "-o", str(output)], check=True)
    subprocess.run([str(output)], check=True, timeout=60)


with tempfile.TemporaryDirectory() as temporary:
    temp = Path(temporary)
    run(temp / "audit-behavior", [ROOT / path for path in [
        "Orvian/Core/API/APIError.swift",
        "Orvian/Core/API/KDriveService+Restore.swift",
        "Orvian/Core/Utils/AsyncPermitPool.swift",
        "Tests/AuditBehaviorChecks.swift",
    ]])
    # Compile the actual view-model methods; only network/cache/UI dependencies
    # are replaced so the command-line test can control response timing.
    vm = source("Orvian/Features/Shared/FileGridViewModel.swift")
    reload_methods = vm[vm.index("    func reload("):vm.index("    /// Pagination infinie")]
    session_guard = vm[vm.index("    private var isCurrentSession:"):vm.index("    private func publish(")]
    grid = temp / "GridLoading.swift"
    grid.write_text('''import Foundation
struct DriveFile { let id: Int }
enum FileSource: Equatable { case directory(Int), recents }
struct FileFilters {
    var serverOrderBy: [String]? { nil }
    var serverOrder: String { "asc" }
}
enum TokenStore {
    static var value = "account-a"
    static func credentialFingerprint() -> String? { value }
}
struct Page {
    var cursor: String? = nil
    var hasMore: Bool? = false
    var data: [DriveFile]? = [DriveFile(id: 1)]
}
@MainActor final class CountServer {
    static let shared = CountServer()
    var pending: [CheckedContinuation<Int, Never>] = []
    func count() async -> Int {
        await withCheckedContinuation { pending.append($0) }
    }
    func finish(_ count: Int) { pending.removeFirst().resume(returning: count) }
}
struct KDriveService {
    func page(_ source: FileSource, driveId: Int, cursor: String?, orderBy: [String]?,
              order: String, forceNetwork: Bool) async throws -> Page { Page() }
    func directoryCount(driveId: Int, directoryId: Int) async throws -> Int {
        await CountServer.shared.count()
    }
}
struct RecentSnapshot {
    var items: [DriveFile] = []
    var cursor: String?
    var hasMore = false
    var fetchedAt = Date()
}
@MainActor final class RecentUploadsLoader {
    static let shared = RecentUploadsLoader()
    static let source = FileSource.recents
    func refresh(driveId: Int, forceNetwork: Bool) async -> RecentSnapshot? { nil }
}
@MainActor final class CategoryLibrary {
    static let shared = CategoryLibrary()
    func ensureLoaded(for driveId: Int) async {}
}
@MainActor final class FileGridViewModel {
    let credentialFingerprint = TokenStore.credentialFingerprint()
    var service = KDriveService()
    var source = FileSource.directory(1)
    var driveId = 7
    var items: [DriveFile] = [] { didSet { itemsRevision += 1 } }
    var itemsRevision = 0
    var orderBy: [String] = []
    var order = "asc"
    var cursor: String?
    var dataGeneration = 0
    var confirmedMutationGeneration = 0
    var orderingNeedsReload = false
    var isLoadingMore = false
    var isReloading = false
    var isInitialLoading = false
    var errorMessage: String?
    var totalItemCount: Int? = nil
    var hasMore = false
    var fetchedAt = Date.distantPast
    var loadedOnce = false
    var storedCounts: [Int] = []
    func storeListSnapshot() { if let totalItemCount { storedCounts.append(totalItemCount) } }
    func filterItemsIfNeeded(_ files: [DriveFile]) -> [DriveFile] { files }
''' + session_guard + reload_methods + "\n}\n", encoding="utf-8")
    run(temp / "grid-loading", [grid, ROOT / "Orvian/Core/API/APIError.swift",
                                ROOT / "Tests/GridLoadChecks.swift"])

for script in ["check_grid_mutation_regressions.py", "check_tag_apply_regressions.py",
               "check_requested_regressions.py", "check_recent_sharing.py"]:
    subprocess.run([sys.executable, str(ROOT / ".github/scripts" / script)], check=True)
