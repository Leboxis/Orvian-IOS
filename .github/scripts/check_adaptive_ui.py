"""Run production layout and dropped-file checks without a simulator."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory() as temporary:
    for name, sources in [
        ("layout", ["Orvian/UI/IPadLayout.swift", "Tests/AdaptiveLayoutChecks.swift"]),
        ("drop", ["Orvian/Core/Utils/DroppedFileStaging.swift", "Tests/DroppedFileChecks.swift"]),
    ]:
        output = Path(temporary) / (name + ".exe")
        subprocess.run(["swiftc", "-swift-version", "5", *[str(ROOT / p) for p in sources],
                        "-o", str(output)], check=True, timeout=60)
        subprocess.run([str(output)], check=True, timeout=60)
