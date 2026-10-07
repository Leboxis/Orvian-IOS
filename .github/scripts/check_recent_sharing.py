"""Run production RecentUploadsLoader against deterministic async cache fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def sources():
    return [ROOT / path for path in [
        "Tests/RecentSharingDependencies.swift",
        "Orvian/Core/Cache/RecentUploadsLoader.swift",
        "Tests/RecentSharingChecks.swift",
    ]]


def main():
    with tempfile.TemporaryDirectory() as temporary:
        executable = Path(temporary) / "recent-sharing-checks"
        subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                        *map(str, sources()), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == "__main__":
    main()
