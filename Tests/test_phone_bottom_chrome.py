"""Source contracts for the floating bottom chrome from a8557473.

The overlays stay within the existing safe area. The grid alone expands
its bottom viewport and reserves clearance for chrome and the home indicator.
These checks do not validate rendered geometry on an iPhone.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class PhoneBottomChromeTests(unittest.TestCase):
    def test_tab_overlay_measures_floating_chrome(self):
        main = read("Orvian/App/MainTabView.swift")
        block = main.split(".overlay(alignment: .bottom)", 1)[1].split(
            "private var bottomNavigationChrome", 1)[0]
        self.assertIn("bottomNavigationChrome", block)
        self.assertIn("onGeometryChange", block)
        self.assertIn("phoneBottomChromeHeight = $0", block)
        self.assertNotIn("safeAreaPadding", block)
        self.assertNotIn("ignoresSafeArea", block)

    def test_bottom_controls_follow_chrome_without_extra_safe_area(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                source = read(path)
                block = source.split(".overlay(alignment: .bottom)", 1)[1].split(
                    ".background {", 1)[0]
                self.assertIn(".padding(.bottom, phoneBottomChromeHeight)", block)
                self.assertNotIn("safeAreaPadding", block)
                self.assertNotIn("ignoresSafeArea", block)

    def test_content_still_reserves_chrome_and_safe_area_once(self):
        grid = read("Orvian/Features/Shared/FileGridView.swift")
        self.assertIn(
            "phoneBottomChromeHeight + contentBottomInset + phoneBrowserBottomInset",
            grid)
        header = read("Orvian/UI/FileBrowserHeader.swift")
        self.assertIn(
            r".environment(\.phoneBrowserBottomInset, geometry.safeAreaInsets.bottom)",
            header)


if __name__ == "__main__":
    unittest.main()
