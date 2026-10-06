"""Compile and exercise the actual Foundation classification policy on macOS."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as temporary:
    output = Path(temporary) / 'image-classification'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    *[str(ROOT / p) for p in [
                        'Orvian/Models/DriveFile.swift', 'Orvian/Models/Category.swift',
                        'Orvian/Core/Utils/FileKind.swift',
                        'Orvian/Core/Classification/ImageClassification.swift',
                        'Tests/ImageClassificationChecks.swift']], '-o', str(output)], check=True)
    subprocess.run([str(output)], check=True, timeout=60)
