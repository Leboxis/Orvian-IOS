"""Compile and run the real DEBUG mailbox/timeline on Windows or macOS."""
from pathlib import Path
import os
import platform
import subprocess
import sys
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="orvian-speech-probe-") as temporary:
        executable = Path(temporary) / ("speech-probe-checks.exe" if os.name == "nt" else "speech-probe-checks")
        # Synchronization.Atomic requires macOS 15+, even when swiftc defaults to an older target.
        target = ["-target", f"{platform.machine()}-apple-macosx15.0"] if sys.platform == "darwin" else []
        # Inherit stdio: capturing child pipes is unsupported by the Windows harness sandbox.
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "DEBUG", *target,
            str(root / "Orvian/Core/Media/SpeechProbeMailbox.swift"),
            str(root / "Tests/SpeechProbeChecks.swift"),
            "-o", str(executable),
        ], check=True, cwd=root, timeout=120)
        subprocess.run([str(executable)], check=True, cwd=root, timeout=30)


if __name__ == "__main__":
    main()
