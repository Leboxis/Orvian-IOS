"""Exercise the grid's production async pagination and directory activation methods."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def fixtures():
    grid = (ROOT / "Orvian/Features/Shared/FileGridView.swift").read_text(encoding="utf-8")
    model = (ROOT / "Orvian/Features/Shared/FileGridViewModel.swift").read_text(encoding="utf-8")
    directory = (ROOT / "Orvian/Features/Home/DirectoryView.swift").read_text(encoding="utf-8")
    activation = block(directory, ".task(id: DirectoryActivationKey(")
    activation = activation[activation.index("{") + 1:activation.rindex("}")]
    return (ROOT / "Tests/AuditBugFixChecks.swift").read_text(encoding="utf-8").replace(
        "// PRODUCTION_PAGINATION", block(grid, "    private func loadMoreAfterMetadataResolution()")
    ).replace(
        "// PRODUCTION_SORT", "\n".join(block(model, marker) for marker in [
            "    func applySort(", "    func syncSort("
        ])
    ).replace("// PRODUCTION_ACTIVATION", activation).replace(
        "// PRODUCTION_REQUESTS", "\n".join(block(grid, marker) for marker in [
            "    private func cancelPagination()", "    private func restartPaginationIfNeeded()",
            "    private func requestMoreFiles("
        ])
    )


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("Swift compiler required for audit regression checks")
    scratch = ROOT / ".tmpcheck"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="audit-bugs-", dir=scratch) as temporary:
        root = Path(temporary)
        source = root / "AuditBugFixChecks.swift"
        source.write_text(fixtures(), encoding="utf-8")
        executable = root / ("audit-bugs.exe" if os.name == "nt" else "audit-bugs")
        subprocess.run([compiler, "-parse-as-library", "-swift-version", "5",
                        str(source), "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
