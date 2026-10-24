"""Compile the production format/error policy; no Apple SDK or media rendering."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    if not shutil.which("swiftc"):
        print("SKIP: Swift compiler unavailable; format policy checks require Swift.")
        return
    scratch = ROOT / ".tmpcheck"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="video-compatibility-", dir=scratch) as temporary:
        executable = Path(temporary) / "video-compatibility.exe"
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5",
            str(ROOT / "Orvian/Core/Media/VideoPlaybackCompatibility.swift"),
            str(ROOT / "Tests/VideoCompatibilityChecks.swift"), "-o", str(executable),
        ], check=True, timeout=90)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
