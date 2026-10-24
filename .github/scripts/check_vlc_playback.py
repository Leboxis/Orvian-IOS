"""Exercise the production VLC wrapper without an iOS SDK, video, or network."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("Swift compiler required for VLC controller behavioral checks")
    production = (ROOT / "Orvian/Features/Viewer/VLCPlaybackController.swift").read_text(encoding="utf-8")
    production, separator, _ = production.partition("struct VLCVideoSurface:")
    assert separator, "controller/surface extraction marker changed"
    production = production.replace("import SwiftUI", "import Foundation").replace("import MobileVLCKit", "")
    tests = (ROOT / "Tests/VLCPlaybackChecks.swift").read_text(encoding="utf-8")
    view = (ROOT / "Orvian/Features/Viewer/VideoPlayerView.swift").read_text(encoding="utf-8")
    seek = view.split("private func seek(to seconds:", 1)[1].split("guard let player else", 1)[0]
    assert "vlcPlayback.hasEnded" in seek
    assert "teardown(preservingPlaybackIntent: true)" in seek
    assert "startVLCPlayback(url: url, at: max(0, seconds))" in seek
    # Keep Windows build scratch inside the declared writable workspace.
    scratch = ROOT / ".tmpcheck" if os.name == "nt" else Path(tempfile.gettempdir())
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="orvian-vlc-check-", dir=scratch) as temporary:
        directory = Path(temporary)
        assert directory.resolve().parent == scratch.resolve(), "unexpected cleanup target"
        source = directory / "VLCPlaybackChecks.swift"
        source.write_text(production + "\n" + tests, encoding="utf-8")
        executable = directory / ("vlc-checks.exe" if os.name == "nt" else "vlc-checks")
        # Inherit stdio; sandboxed Windows named-pipe capture is not supported.
        subprocess.run([compiler, "-parse-as-library", "-swift-version", "5",
                        str(source), "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
