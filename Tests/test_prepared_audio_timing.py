"""Execute production AnalyzerInput construction with timing-only host shims."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PreparedAudioTimingTests(unittest.TestCase):
    def test_real_input_buffers_never_overlap_on_the_source_timeline(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("Swift compiler unavailable")
        decoder = (ROOT / "Orvian/Core/Media/PreparedAudioDecoder.swift").read_text(encoding="utf-8")
        chunk = "struct PreparedAudioChunk:" + decoder.split("struct PreparedAudioChunk:", 1)[1].split("/// Serial ownership", 1)[0]
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "ProductionInput.swift"
            source.write_text("import Foundation\n" + chunk, encoding="utf-8")
            executable = Path(temporary) / ("timing.exe" if os.name == "nt" else "timing")
            subprocess.run([
                compiler, "-parse-as-library", "-swift-version", "5",
                str(ROOT / "Tests/PreparedAudioTimingShims.swift"), str(source),
                str(ROOT / "Tests/PreparedAudioTimingChecks.swift"), "-o", str(executable),
            ], check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    unittest.main()
