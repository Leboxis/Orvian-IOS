"""Nonvisual contracts for the pinned native playback dependency."""
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VLCKitDependencyTests(unittest.TestCase):
    def test_official_stable_pod_is_exactly_pinned(self):
        podfile = (ROOT / "Podfile").read_text(encoding="utf-8")
        self.assertIn("source 'https://cdn.cocoapods.org/'", podfile)
        self.assertIn("pod 'MobileVLCKit', '3.7.4'", podfile)
        self.assertIn("target 'OrvianTests'", podfile)
        self.assertIn("inherit! :search_paths", podfile)

    def test_every_ci_xcodebuild_uses_cocoapods_workspace(self):
        for name in ("build.yml", "checks.yml"):
            with self.subTest(workflow=name):
                text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
                self.assertNotIn("-project Orvian.xcodeproj", text)
                self.assertIn("-workspace Orvian.xcworkspace", text)
                self.assertIn("brew install xcodegen cocoapods", text)
                self.assertIn("xcodegen generate\n          pod install", text)

    def test_full_generated_licenses_have_a_settings_entry(self):
        with (ROOT / "Orvian/Resources/Settings.bundle/Root.plist").open("rb") as source:
            settings = plistlib.load(source)
        panes = settings["PreferenceSpecifiers"]
        self.assertTrue(any(pane.get("File") == "Acknowledgements" for pane in panes))
        self.assertTrue(any("LGPL" in pane.get("FooterText", "") for pane in panes))
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("Pods-Orvian-acknowledgements.plist", project)
        self.assertIn("Settings.bundle/Acknowledgements.plist", project)


if __name__ == "__main__":
    unittest.main()
