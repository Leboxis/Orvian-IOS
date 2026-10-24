"""Exercise the production diagnostic formatter, without Apple SDKs or media."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PreparedSubtitleDiagnosticsTests(unittest.TestCase):
    def test_real_swift_formatter_reports_stage_codes_and_redacts_private_data(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("Swift compiler unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / ("diagnostics.exe" if os.name == "nt" else "diagnostics")
            subprocess.run([
                compiler, "-parse-as-library", "-swift-version", "5",
                str(ROOT / "Orvian/Core/Media/PreparedSubtitleDiagnostics.swift"),
                str(ROOT / "Tests/PreparedSubtitleDiagnosticsChecks.swift"),
                "-o", str(executable),
            ], check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=30)

    def test_job_and_analyzer_connect_stage_diagnostics(self):
        job = (ROOT / "Orvian/Features/Viewer/PreparedSubtitleSheet.swift").read_text(encoding="utf-8")
        analyzer = (ROOT / "Orvian/Core/Media/PreparedSubtitleAnalyzer.swift").read_text(encoding="utf-8")
        self.assertIn("self.error = stage.failureMessage(for: error, explanation: explanation)", job)
        self.assertIn("await self?.setStage(value)", job)
        self.assertIn("catch is CancellationError", job)
        for stage in ("translationModels", "translation", "saving"):
            self.assertIn(f"stage = .{stage}", job)
        for stage in ("audio", "speechModels", "speechPreparation", "transcription", "speechFinishing"):
            self.assertIn(f"await stage(.{stage})", analyzer)
        self.assertNotIn("Vérifiez les modèles de langue, la connexion", job)


if __name__ == "__main__":
    unittest.main()
