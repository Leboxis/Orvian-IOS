"""Run the production cache and Codable models on the macOS CI runner."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    # Only the value type is needed; the store itself depends on the app session.
    source = (root / "Orvian/Core/Cache/DirectoryListStore.swift").read_text()
    snapshot = source[source.index("struct DirectoryListSnapshot"):source.index("\n/// Mémoire")]
    model = temporary / "Snapshot.swift"
    model.write_text("import Foundation\n" + snapshot)
    executable = temporary / "cache-checks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5",
        str(model),
        str(root / "Orvian/Models/DriveFile.swift"),
        str(root / "Orvian/Models/Category.swift"),
        str(root / "Orvian/Core/Utils/FileKind.swift"),
        str(root / "Orvian/Core/Cache/FavoritesDiskCache.swift"),
        str(root / "Tests/FavoritesDiskCacheChecks.swift"),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
