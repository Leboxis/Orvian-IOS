"""Compile and exercise production iOS helpers on the macOS runner, in Swift 5 mode."""
from pathlib import Path
import subprocess
import tempfile
import platform

ROOT = Path(__file__).resolve().parents[2]


def run_check(output, sources):
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                    "-target", f"{platform.machine()}-apple-macosx14.0",
                    *map(str, sources), "-o", str(output)], check=True)
    subprocess.run([str(output)], check=True, timeout=60)


with tempfile.TemporaryDirectory() as temporary:
    temp = Path(temporary)
    # Compile real production code, not a Python model of its concurrency.
    # Same-file extensions can pause at private snapshot/publication boundaries.
    perf_checks = temp / "PerfChecks.swift"
    perf_checks.write_text(
        (ROOT / "Orvian/Core/Utils/Perf.swift").read_text(encoding="utf-8")
        + "\n" + (ROOT / "Tests/PerfChecks.swift").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    run_check(temp / "perf", [perf_checks])
    run_check(temp / "text-search", [ROOT / path for path in [
        "Orvian/Features/Viewer/TextSearch.swift", "Tests/TextSearchChecks.swift",
    ]])
    run_check(temp / "text-content", [ROOT / path for path in [
        "Orvian/Core/Utils/TextFileContent.swift", "Tests/TextFileContentChecks.swift",
    ]])
    # UIKit is unavailable on the macOS command-line target. Exercise the
    # view's actual methods with plain state; Xcode still compiles the full UI.
    viewer = (ROOT / "Orvian/Features/Viewer/TextFileViewer.swift").read_text(encoding="utf-8")
    search_methods = viewer[viewer.index("    private func scheduleSearchUpdate()"):
                            viewer.index("    private func goToNext()")]
    lifecycle_checks = temp / "TextSearchLifecycleChecks.swift"
    lifecycle_checks.write_text('''import Foundation
@MainActor final class TextFileViewer {
    var isSearching = false
    var searchQuery = ""
    var draft = ""
    var searchRanges: [NSRange] = []
    var currentSearchIndex: Int?
    var searchGeneration = 0
    var searchTask: Task<Void, Never>?
''' + search_methods + "\n}\n"
        + (ROOT / "Tests/TextSearchLifecycleChecks.swift").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    run_check(temp / "text-search-lifecycle", [lifecycle_checks,
              ROOT / "Orvian/Features/Viewer/TextSearch.swift"])
    upload_source = (ROOT / "Orvian/Core/API/KDriveService+Upload.swift").read_text(encoding="utf-8")
    chunk_checks = temp / "UploadChunkChecks.swift"
    chunk_checks.write_text(
        upload_source[:upload_source.index("/// Création de dossiers, upload simple")]
        + "\n" + (ROOT / "Tests/UploadChunkChecks.swift").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    run_check(temp / "upload-chunks", [chunk_checks])
    run_check(temp / "video-playback", [ROOT / path for path in [
        "Orvian/Features/Viewer/VideoPlaybackTransport.swift",
        "Tests/VideoPlaybackChecks.swift",
    ]])
    run_check(temp / "security", [ROOT / path for path in [
        "Orvian/Core/Auth/PINCredential.swift", "Orvian/Core/Auth/KeychainSupport.swift",
        "Orvian/Core/Auth/PINRecordStore.swift",
        "Tests/SecurityChecks.swift",
    ]])
    run_check(temp / "transfers", [ROOT / path for path in [
        "Orvian/Core/Utils/TransferCompletion.swift", "Orvian/Core/Utils/BoundedDataLoader.swift",
        "Orvian/Core/API/APIError.swift", "Orvian/Core/Utils/UploadSafety.swift",
        "Tests/TransferChecks.swift",
    ]])
    lock_storage = temp / "LockStorage.swift"
    lock_storage.write_text('''import Foundation
final class PINRecordStore {
    static var value: String?
    static var allowWrites = true
    func current() -> String? { Self.value }
    func save(_ value: String) -> Bool {
        guard Self.allowWrites else { return false }
        Self.value = value
        return true
    }
    func clear() { Self.value = nil }
}
''', encoding="utf-8")
    run_check(temp / "lock-store", [lock_storage, ROOT / "Orvian/Core/Auth/PINCredential.swift",
                                    ROOT / "Orvian/Core/Auth/AppLockStore.swift",
                                    ROOT / "Tests/AppLockChecks.swift"])
    # Replace only network/session/UI dependencies; compile the real metadata store.
    dependencies = temp / "MetadataDependencies.swift"
    dependencies.write_text('''import Foundation
import AVFoundation
enum FileFilters {
    enum Orientation: String, Codable { case landscape, portrait, square }
}
struct DriveFile {
    let id: Int
    var isVideo: Bool { true }
    var size: Int? { nil }
    var lastModifiedAt: Double? { nil }
}
enum TokenStore {
    static var credential = "account-a"
    static func credentialFingerprint() -> String? { credential }
}
@MainActor final class VideoAssetCache {
    static let shared = VideoAssetCache()
    func asset(driveId: Int, fileId: Int) async -> AVURLAsset? { nil }
}
''', encoding="utf-8")
    run_check(temp / "metadata", [dependencies, ROOT / "Orvian/Core/Media/MediaMetadataStore.swift",
                                   ROOT / "Tests/MediaMetadataChecks.swift"])

    # Exercise actual move handling and cache invalidation without the HTTP client.
    mutation_dependencies = temp / "MutationDependencies.swift"
    service = (ROOT / "Orvian/Core/API/KDriveService.swift").read_text(encoding="utf-8")
    source_type = service[service.index("enum FileSource"):service.index("/// Couche Repository")]
    cache = (ROOT / "Orvian/Core/Cache/DirectoryListStore.swift").read_text(encoding="utf-8")
    snapshot_type = cache[cache.index("struct DirectoryListSnapshot"):cache.index("/// Mémoire")]
    mutation_dependencies.write_text(
        "import Foundation\n" + source_type + snapshot_type
        + 'enum TokenStore { static func credentialFingerprint() -> String? { "test-account" } }\n',
        encoding="utf-8",
    )
    run_check(temp / "mutation-safety", [mutation_dependencies, *[ROOT / path for path in [
        "Orvian/Models/DriveFile.swift", "Orvian/Models/Category.swift",
        "Orvian/Core/Utils/FileKind.swift",
        "Orvian/Features/Shared/FileGridMutationCenter.swift",
        "Tests/MutationSafetyChecks.swift",
    ]]])

    # Real sorting/search pipeline: the actual FileFilters, the actual
    # FileSource ordering rules and the actual models. Only the AVFoundation
    # metadata types are replaced, because the filters only read their table.
    filters_dependencies = temp / "FileFiltersDependencies.swift"
    filters_dependencies.write_text(
        "import Foundation\n" + source_type
        + "\nstruct VideoMetadataInfo: Sendable {\n"
        + "    let duration: Double\n"
        + "    let orientation: FileFilters.Orientation\n"
        + "    let maximumDimension: CGFloat\n"
        + "    var is4KOrAbove: Bool { maximumDimension >= 3_840 }\n"
        + "}\n"
        + "struct VideoMetadataSnapshot: Sendable {\n"
        + "    private let infos: [Int: VideoMetadataInfo]\n"
        + "    init(infos: [Int: VideoMetadataInfo] = [:]) { self.infos = infos }\n"
        + "    func info(for fileId: Int) -> VideoMetadataInfo? { infos[fileId] }\n"
        + "}\n",
        encoding="utf-8",
    )
    run_check(temp / "file-filters", [filters_dependencies, *[ROOT / path for path in [
        "Orvian/Core/API/FileSource+Ordering.swift",
        "Orvian/Models/FileFilters.swift",
        "Orvian/Models/DriveFile.swift",
        "Orvian/Models/Category.swift",
        "Orvian/Core/Utils/FileKind.swift",
        "Tests/FileFiltersChecks.swift",
    ]]])
