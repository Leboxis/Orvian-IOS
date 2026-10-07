"""Compile actual ApplyTagsSheet mutation methods with controllable network/UI stubs.

Run on macOS CI with swiftc. --check-source validates extraction without Swift.
This script is intentionally independent of the shared audit runner.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def harness_source():
    sheet = (ROOT / "Orvian/Features/Home/ApplyTagsSheet.swift").read_text(encoding="utf-8")
    types = sheet[sheet.index("struct TagChange {"):sheet.index("struct ApplyTagsSheet: View {")]
    state = sheet[sheet.index("    private enum TagState {"):sheet.index("    var body: some View {")]
    guard = sheet[sheet.index("    private var isCurrentMutationSession:"):sheet.index("    private let service =")]
    selection = sheet[sheet.index("    private func countHaving("):sheet.index("    private func load()") ]
    mutations = sheet[sheet.index("    private func apply() async {"):sheet.rindex("\n}")]
    # Keep every production branch and credential/cancellation guard intact; only
    # SwiftUI state storage, rendering and the external service are stubbed.
    return "import Foundation\n" + types + """
@MainActor final class TagSheetHarness {
    let driveId = 7
    let files: [DriveFile]
    let service = KDriveService()
    let mutationCredentialFingerprint = TokenStore.credentialFingerprint()
    var addIDs: Set<Int> = []
    var removeIDs: Set<Int> = []
    var confirmedTagOverrides: [Int: [Int: Bool]] = [:]
    var busy = false
    var errorMessage: String?
    var deliveries: [[TagChange]] = []
    var dismissed = false
    var changeIdentityOnDone = false
    init(_ files: [DriveFile]) { self.files = files }
    func dismiss() { dismissed = true }
    func onDone(_ changes: [TagChange]) async {
        deliveries.append(changes)
        if changeIdentityOnDone { TokenStore.value = "account-b" }
    }
""" + (guard + state + selection + mutations).replace("private ", "") + "\n}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-source", action="store_true")
    args = parser.parse_args()
    harness = harness_source()
    assert harness.count("{") == harness.count("}"), "Unbalanced extraction"
    assert "fallback.error ??" not in harness, "Bulk failure must not survive successful fallback"
    assert "applyOneByOne(files: targets" in harness
    assert "reconcile(appliedChanges)" in harness
    assert "guard isCurrentMutationSession else { return }" in harness
    if args.check_source:
        print("Tag regression harness extraction checked (Swift execution not performed)")
        return
    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        extracted = temp / "TagSheetHarness.swift"
        extracted.write_text(harness, encoding="utf-8")
        output = temp / "tag-apply-checks"
        subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                        str(extracted),
                        str(ROOT / "Orvian/Core/API/APIError.swift"),
                        str(ROOT / "Orvian/Core/Utils/BoundedConcurrency.swift"),
                        str(ROOT / "Tests/TagApplyChecks.swift"),
                        "-o", str(output)], check=True)
        subprocess.run([str(output)], check=True, timeout=60)


if __name__ == "__main__":
    main()
