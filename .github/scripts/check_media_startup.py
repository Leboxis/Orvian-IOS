"""Exercise production video cache with controlled URL and AVFoundation stubs."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

STUBS = r'''
import Foundation
@MainActor enum TokenStore {
    static func credentialFingerprint() -> String? { "account-a" }
}
@MainActor final class MediaURLCache {
    static let shared = MediaURLCache()
    var calls = 0
    var invalidations = 0
    var holdInvalidations = false
    var invalidationWaiters: [CheckedContinuation<Void, Never>] = []
    var waiters: [CheckedContinuation<URL?, Never>] = []
    func url(driveId: Int, fileId: Int) async -> URL? {
        calls += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func freshURL(driveId: Int, fileId: Int) async -> URL? {
        await url(driveId: driveId, fileId: fileId)
    }
    func invalidate(driveId: Int, fileId: Int) async {
        if holdInvalidations {
            await withCheckedContinuation { invalidationWaiters.append($0) }
        }
        invalidations += 1
    }
    func complete() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: URL(string: "https://example.invalid/video"))
        }
    }
}
@MainActor final class AVURLAsset {
    enum Property { case isPlayable }
    static var pendingLoads: [CheckedContinuation<Bool, Error>] = []
    let url: URL
    init(url: URL) { self.url = url }
    func load(_ property: Property) async throws -> Bool {
        try await withCheckedThrowingContinuation { Self.pendingLoads.append($0) }
    }
}
'''


def main():
    if not shutil.which("swiftc"):
        print("SKIP: Swift compiler unavailable; behavioral media checks require Swift.")
        return
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        source = directory / "MediaStartupChecks.swift"
        production = (ROOT / "Orvian/Core/Media/VideoAssetCache.swift").read_text(encoding="utf-8")
        tests = (ROOT / "Tests/VideoAssetCacheChecks.swift").read_text(encoding="utf-8")
        source.write_text(STUBS + production.replace("import AVFoundation", "") + tests, encoding="utf-8")
        executable = directory / "media-startup"
        subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                        str(source), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
