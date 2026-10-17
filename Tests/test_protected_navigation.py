"""Permanent UI contracts requested by the owner; runtime tests live in iOS tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding="utf-8")

class ProtectedNavigationTests(unittest.TestCase):
    def test_exact_tab_order_and_profile_title(self):
        bar = read("Orvian/UI/FloatingTabBar.swift")
        self.assertIn("[.settings, .tag, .home, .favorites, .profile]", bar)
        self.assertIn('case .profile: return "Profil"', bar)
        tabs = read("Orvian/App/IPadTabView.swift")
        self.assertEqual(re.findall(r"value: AppTab\.(\w+)", tabs),
                         ["settings", "tag", "home", "favorites", "profile"])

    def test_favorites_never_waits_for_a_child_report_to_enable_actions(self):
        for path in ["Favorites/FavoritesView.swift", "Home/DirectoryView.swift"]:
            source = read("Orvian/Features/" + path)
            self.assertIn("visibleSnapshot(", source)
            self.assertNotIn("visibleItemsReport", source)

    def test_commands_are_separate_and_in_the_requested_order(self):
        toolbar = read("Orvian/Features/Shared/BrowserToolbar.swift")
        self.assertLess(toolbar.index("onRandom" , toolbar.index("var body")),
                        toolbar.index("onSelect", toolbar.index("var body")))
        self.assertNotIn("Menu {", toolbar)

    def test_details_is_read_only_and_uses_the_native_inspector(self):
        details = read("Orvian/Features/Shared/FileDetailSheet.swift")
        for action in ["onDelete", "onRename", "onToggleFavorite", "onOpen", "actionsSection", "openSection"]:
            self.assertFalse(action in details, f"Détails must not contain {action}")
        self.assertIn(".inspector(isPresented:", read("Orvian/Features/Shared/FileGridView.swift"))

    def test_pad_catalogue_grid_opens_the_pad_detail(self):
        tags = read("Orvian/Features/Tag/TagsView.swift")
        opening = tags[tags.index("    private func open(_ category:"):tags.index("    private func push(")]
        self.assertTrue("padNavigation.select(category.id)" in opening,
                        "An iPad catalogue grid tap must update the visible iPad stack, not the hidden phone path")

    def test_details_publishes_resolved_video_metadata(self):
        details = read("Orvian/Features/Shared/FileDetailSheet.swift")
        self.assertTrue("@State private var videoInfo:" in details,
                        "Resolved video metadata must publish state after its async load")

    def test_ci_keeps_security_assertions_but_never_captures_privacy_images(self):
        privacy = read("Tests/iOS/PrivacyWindowTests.swift")
        self.assertNotIn("UIGraphicsImageRenderer", privacy)
        self.assertNotIn("XCTAttachment(image:", privacy)
        self.assertIn("XCTAssertTrue(owner.accessibilityElementsHidden)", privacy)

    def test_generic_browser_announces_its_actual_scope_and_partial_counts(self):
        browser = read("Orvian/Features/Favorites/FavoritesView.swift")
        self.assertTrue('accessibilityLabel("Rechercher dans \\(title)")' in browser)
        self.assertTrue('éléments chargés' in browser)

if __name__ == "__main__":
    unittest.main()
