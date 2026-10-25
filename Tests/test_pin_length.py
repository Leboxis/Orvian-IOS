"""UI/CI wiring for six-digit setup and compatible existing-lock verification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PINLengthWiringTests(unittest.TestCase):
    def test_setup_uses_old_length_only_while_verifying_current_code(self):
        setup = (ROOT / "Orvian/Features/Security/AppLockSetupSheet.swift").read_text(encoding="utf-8")
        self.assertIn("stage == .verifyCurrent ? AppLockStore.codeLength : PINCredential.newCodeLength", setup)
        self.assertIn("CodeDots(filledCount: code.count, length: codeLength", setup)
        self.assertIn("guard code.count == codeLength", setup)
        self.assertIn("try await AppLockStore.save(code)", setup)

    def test_unlock_uses_length_of_persisted_credential(self):
        lock = (ROOT / "Orvian/Features/Security/AppLockView.swift").read_text(encoding="utf-8")
        self.assertIn("private var codeLength: Int { AppLockStore.codeLength }", lock)
        self.assertIn("guard code.count == codeLength", lock)
        store = (ROOT / "Orvian/Core/Auth/AppLockStore.swift").read_text(encoding="utf-8")
        self.assertIn("PINCredential.requiredLength(for: store.current())", store)
        self.assertIn("try PINCredential.upgradeLegacy(code)", store)
        self.assertIn("try PINCredential.make(code)", store)

    def test_regressions_run_in_existing_pr_checks(self):
        workflow = (ROOT / ".github/workflows/checks.yml").read_text(encoding="utf-8")
        self.assertIn("python3 .github/scripts/check_pin_length.py", workflow)
        self.assertIn("python3 -m unittest discover -s Tests -p 'test_pin_length.py'", workflow)
        self.assertNotIn("\n  push:", workflow)


if __name__ == "__main__":
    unittest.main()
