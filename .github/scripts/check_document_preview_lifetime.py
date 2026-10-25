"""Exercise real preview ownership without rendering QuickLook or requiring iOS."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def check():
    source = (ROOT / "Orvian/Features/Viewer/DocumentPreviewView.swift").read_text(encoding="utf-8")
    # The UI must share the tested owner, not pass a naked URL and remove it on
    # disappearance while QuickLook or its share presentation still needs it.
    assert "@State private var lifetime = DocumentPreviewLifetime()" in source
    assert "await lifetime.load {" in source
    assert ".onDisappear { lifetime.cancelLoading() }" in source
    assert "didDismantle" not in source
    assert "controller.retainedItem = context.coordinator.item" in source
    assert "let copy: DocumentPreviewCopy" in source
    assert "var previewItemURL: URL? { copy.url }" in source
    assert "removeCopy(" not in source
    assert source.count("try Task.checkCancellation()") >= 3
    assert 'Button("Réessayer") { retry &+= 1 }' in source
    with tempfile.TemporaryDirectory(prefix="orvian-preview-checks-") as temporary:
        executable = Path(temporary) / ("preview.exe" if os.name == "nt" else "preview")
        subprocess.run([
            "swiftc", "-swift-version", "5", "-parse-as-library",
            str(ROOT / "Orvian/Core/Utils/DocumentPreviewLifetime.swift"),
            str(ROOT / "Tests/DocumentPreviewLifetimeChecks.swift"),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    check()
