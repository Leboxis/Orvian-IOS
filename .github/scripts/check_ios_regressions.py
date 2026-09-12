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
    run_check(temp / "security", [ROOT / path for path in [
        "Orvian/Core/Auth/PINCredential.swift", "Orvian/Core/Auth/KeychainSupport.swift",
        "Orvian/Core/Auth/PINRecordStore.swift",
        "Tests/SecurityChecks.swift",
    ]])
    run_check(temp / "transfers", [ROOT / path for path in [
        "Orvian/Core/Utils/TransferCompletion.swift", "Orvian/Core/Utils/BoundedDataLoader.swift",
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
