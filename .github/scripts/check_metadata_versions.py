"""Compile the real metadata store with offline AVFoundation/network doubles."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
STUBS = r'''
import Foundation

enum FileFilters {
    enum Orientation: String, Codable, Sendable { case landscape, portrait, square }
}
struct DriveFile: Sendable {
    let id: Int
    var size: Int? = nil
    var lastModifiedAt: Double? = nil
    var isVideo: Bool { true }
}
@MainActor enum TokenStore {
    static var credential = "account-a"
    static func credentialFingerprint() -> String? { credential }
}
actor MetadataLoads {
    static let shared = MetadataLoads()
    var pending: [Int: CheckedContinuation<Double, Never>] = [:]
    func load(_ id: Int) async -> Double {
        await withCheckedContinuation { pending[id] = $0 }
    }
    func contains(_ id: Int) -> Bool { pending[id] != nil }
    func complete(_ id: Int, duration: Double) {
        pending.removeValue(forKey: id)!.resume(returning: duration)
    }
}
struct MetadataTime { let seconds: Double }
struct MetadataSize {
    let width: CGFloat
    let height: CGFloat
    func applying(_ transform: MetadataTransform) -> Self { self }
}
struct MetadataTransform {}
struct MetadataTrack {
    enum SizeProperty { case naturalSize }
    enum TransformProperty { case preferredTransform }
    func load(_ property: SizeProperty) async throws -> MetadataSize {
        MetadataSize(width: 1920, height: 1080)
    }
    func load(_ property: TransformProperty) async throws -> MetadataTransform { MetadataTransform() }
}
final class AVURLAsset: Sendable {
    enum Property { case duration }
    enum MediaType { case video }
    let id: Int
    init(id: Int) { self.id = id }
    func load(_ property: Property) async throws -> MetadataTime {
        MetadataTime(seconds: await MetadataLoads.shared.load(id))
    }
    func loadTracks(withMediaType type: MediaType) async throws -> [MetadataTrack] { [] }
}
@MainActor final class VideoAssetCache {
    static let shared = VideoAssetCache()
    var calls = 0
    var invalidations: [Int] = []
    var nextAsset: AVURLAsset?
    func asset(driveId: Int, fileId: Int) async -> AVURLAsset? {
        calls += 1
        return nextAsset
    }
    func invalidate(driveId: Int, fileId: Int) { invalidations.append(fileId) }
}
'''


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("Swift compiler required for metadata version regression checks")
    with tempfile.TemporaryDirectory(prefix="orvian-metadata-versions-") as temporary:
        directory = Path(temporary)
        production = (ROOT / "Orvian/Core/Media/MediaMetadataStore.swift").read_text(encoding="utf-8")
        for test_name in ["MetadataVersionChecks", "MediaMetadataChecks"]:
            source = directory / (test_name + ".swift")
            checks = (ROOT / "Tests" / (test_name + ".swift")).read_text(encoding="utf-8")
            source.write_text(STUBS + production.replace("import AVFoundation", "") + checks, encoding="utf-8")
            executable = directory / (test_name + (".exe" if os.name == "nt" else ""))
            subprocess.run([compiler, "-parse-as-library", "-swift-version", "5", str(source),
                            "-o", str(executable)], check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
