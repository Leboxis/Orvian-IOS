"""Source contracts for the floating iPhone browser header.

These checks cannot prove the rendered transition on a device. Keep the
native toolbar and a soft top scroll edge instead of the old hidden edge
policy that belonged to the clipped header layout.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class PhoneBrowserTopTests(unittest.TestCase):
    def test_phone_grid_uses_soft_native_transition(self):
        source = read("Orvian/Features/Shared/FileGridView.swift")
        self.assertIn(
            ".scrollEdgeEffectStyle(iPadLayout.isPad ? nil : .soft, for: .top)",
            source)
        self.assertNotIn(".scrollEdgeEffectHidden(", source)

    def test_browsers_keep_native_toolbar_background(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                source = read(path)
                self.assertNotIn(".toolbarBackground(", source)
                self.assertNotIn(".toolbarBackgroundVisibility(", source)

    def test_browsers_keep_an_empty_inline_title(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                source = read(path)
                self.assertIn('.navigationTitle("")', source)
                self.assertIn(".navigationBarTitleDisplayMode(.inline)", source)

    def test_folder_changes_freeze_the_system_buttons(self):
        # `disablesAnimations` ne couvre que l'arbre SwiftUI : sans ce gel,
        # les boutons fixes de la barre se fondent encore à chaque ouverture
        # de dossier et à chaque retour.
        expected = {"Orvian/Features/Home/HomeTab.swift": 4,
                    "Orvian/Features/Favorites/FavoritesView.swift": 3,
                    "Orvian/Features/Tag/TagsView.swift": 2}
        for path, count in expected.items():
            with self.subTest(path=path):
                source = read(path)
                self.assertGreaterEqual(source.count("Motion.withoutNavigationAnimation"), count)

        motion = read("Orvian/UI/Motion.swift")
        freeze = motion[motion.index("static func withoutNavigationAnimation"):]
        self.assertIn("UIView.setAnimationsEnabled(false)", freeze)
        self.assertIn("UIView.setAnimationsEnabled(true)", freeze)
        self.assertIn("UIDevice.current.userInterfaceIdiom != .pad", freeze)
        self.assertIn("transaction.disablesAnimations = true", freeze)


if __name__ == "__main__":
    unittest.main()
