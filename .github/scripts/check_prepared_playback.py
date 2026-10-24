"""Exercise production prepared-caption playback without Apple SDKs or rendering."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("Swift compiler required for prepared caption playback checks")
    production = (ROOT / "Orvian/Core/Media/PreparedSubtitles.swift").read_text(encoding="utf-8")
    model, marker, _ = production.partition("struct PreparedSpeechSpan:")
    assert marker, "prepared model extraction marker changed"
    model = model.replace("import NaturalLanguage", "")
    checks = (ROOT / "Tests/PreparedSubtitlePlaybackChecks.swift").read_text(encoding="utf-8")
    scratch = ROOT / ".tmpcheck"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="prepared-playback-", dir=scratch) as temporary:
        directory = Path(temporary)
        source = directory / "PreparedPlaybackChecks.swift"
        source.write_text(model + "\n" + checks, encoding="utf-8")
        executable = directory / ("prepared-playback.exe" if os.name == "nt" else "prepared-playback")
        subprocess.run([
            compiler, "-parse-as-library", "-swift-version", "5",
            str(ROOT / "Orvian/Core/Media/SubtitleCue.swift"),
            str(ROOT / "Orvian/Features/Viewer/PreparedSubtitlePlayback.swift"),
            str(source), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
