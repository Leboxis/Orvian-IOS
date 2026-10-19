"""Compile the actual inspector model with controllable external dependencies."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as temporary:
    executable = Path(temporary) / "details.exe"
    paths = ["Tests/FileDetailsDependencies.swift", "Orvian/Features/Shared/FileDetailsViewModel.swift", "Tests/FileDetailsChecks.swift"]
    subprocess.run(["swiftc", "-swift-version", "5", *[str(ROOT / p) for p in paths], "-o", str(executable)], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=60)
    executable = Path(temporary) / "directory-size.exe"
    paths = ["Orvian/Models/DriveModels.swift", "Tests/DirectorySizeChecks.swift"]
    subprocess.run(["swiftc", "-swift-version", "5", *[str(ROOT / p) for p in paths], "-o", str(executable)], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=60)
