"""Only IPA publication runs automatically when main receives a push."""
from fnmatch import fnmatchcase
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"


class WorkflowTriggerTests(unittest.TestCase):
    def test_only_ipa_runs_on_main_push(self):
        main_workflows = []
        for path in WORKFLOWS.glob("*.yml"):
            text = path.read_text(encoding="utf-8")
            push = re.search(r"^  push:\n(.*?)(?=^  [a-z_]+:|^\S|\Z)", text, re.M | re.S)
            if not push:
                continue
            # The repository uses inline branch allowlists. Fail if that changes
            # rather than overlooking a new unrestricted main trigger.
            branches = re.search(r"^    branches: \[([^\]]+)\]$", push[1], re.M)
            self.assertIsNotNone(branches, f"Review push branch rules in {path.name}")
            patterns = [item.strip().strip("\"'") for item in branches[1].split(",")]
            if any(fnmatchcase("main", pattern) for pattern in patterns):
                main_workflows.append(path.name)
        self.assertEqual(main_workflows, ["build.yml"])

    def test_checks_remain_available_manually(self):
        for name in ("checks.yml", "audio-tap-safety.yml", "subtitle-quality.yml"):
            self.assertIn("  workflow_dispatch:", (WORKFLOWS / name).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
