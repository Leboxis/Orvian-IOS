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
