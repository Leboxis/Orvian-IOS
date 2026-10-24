"""Source contracts for the iPad shell; runtime checks live in IPadNavigationTests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IPadNavigationWiringChecks(unittest.TestCase):
    def source(self, name):
        path = ROOT / name
        self.assertTrue(path.is_file(), f"Missing implementation: {name}")
        return path.read_text(encoding="utf-8")

    def test_native_ipad_toolbar_fixture_runs_only_on_the_ipad_destination(self):
        tests = self.source("Tests/iOS/BrowserPresentationTests.swift")
        fixture = tests.split("func testCardTitleUsesNinetyFivePercentAndPadSummarySharesTopToolbar()", 1)[1]
        self.assertIn("XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad", fixture)
        self.assertLess(fixture.index("XCTSkipIf("), fixture.index("IPadTabView("))
        self.assertIn("XCTAssertEqual(frames.title.width, 228", fixture)
        self.assertIn("XCTAssertEqual(frames.header.midY, command.midY", fixture)
        workflow = self.source(".github/workflows/checks.yml")
        pad = workflow.split("- name: Verify native iPad details presentations", 1)[1]
        self.assertIn("platform=iOS Simulator,id=$IPAD_ID", pad)
        self.assertIn("-only-testing:OrvianTests/BrowserPresentationTests", pad)
        self.assertNotIn("-skip-testing:OrvianTests/BrowserPresentationTests", workflow)

    def test_ipad_uses_native_tabs_instead_of_the_phone_stack_overlay(self):
        main = self.source("Orvian/App/MainTabView.swift")
        self.assertIn("private var phoneNavigation:", main)
        body = main[main.index("    var body:"):main.index("    private var phoneNavigation:")]
        self.assertIn("UIDevice.current.userInterfaceIdiom == .pad", body)
        self.assertIn("IPadTabView(selection: iPadSelection)", body)
        self.assertIn("tabContent(tab)", body)
        self.assertIn("phoneNavigation", body)
        self.assertNotIn("tabPane(", body)

    def test_native_container_declares_five_distinct_tabs_without_hidden_stacks(self):
        native = self.source("Orvian/App/IPadTabView.swift")
        self.assertIn("TabView(selection: $selection)", native)
        self.assertIn(".tabViewStyle(.tabBarOnly)", native)
        self.assertEqual(
            re.findall(r"value: AppTab\.(\w+)", native),
            ["settings", "tag", "home", "favorites", "profile"],
        )
        for forbidden in ["NavigationSplitView", "NavigationStack", "ZStack", ".opacity(", "tabPane("]:
            self.assertNotIn(forbidden, native)
        for tab in ["home", "favorites", "tag", "profile", "settings"]:
            self.assertEqual(native.count(f"content(.{tab})"), 1)
        for forbidden in ["Color(", ".tint(", "colorScheme", ".background("]:
            self.assertNotIn(forbidden, native)

    def test_phone_keeps_its_floating_bar_and_reselection_behavior(self):
        main = self.source("Orvian/App/MainTabView.swift")
        self.assertIn("private var phoneNavigation:", main)
        phone = main[main.index("    private var phoneNavigation:"):main.index("    private var iPadSelection:")]
        for expected in [
            "safeAreaInset(edge: .bottom, spacing: 0)", "FloatingTabBar(",
            "selection: $shell.tab", "onSelect: prepareTab", "onReselect:",
            "scrollFavoritesToTop: favoritesReselectScrollToTop", "TransferOverlayChrome(",
        ]:
            self.assertIn(expected, phone)
        self.assertNotIn("IPadTabView(", phone)
        self.assertIn("target == shell.tab || (target.isKeptAlive && shell.visitedTabs.contains(target))", main)

    def test_presentations_and_profile_prefetch_keep_their_shared_owners(self):
        main = self.source("Orvian/App/MainTabView.swift")
        self.assertIn("private var phoneNavigation:", main)
        body = main[main.index("    var body:"):main.index("    private var phoneNavigation:")]
        # Trois présentations plein écran : pager média, éditeur de texte et
        # aperçu de document (QuickLook).
        self.assertEqual(body.count(".fullScreenCover("), 3)
        self.assertEqual(body.count(".sheet("), 1)
        self.assertIn(".tint(.accentColor)", body)
        self.assertIn("shell.markVisited(targetTab)", main)
        self.assertIn("RecentUploadsLoader.shared.prefetch(driveId: drive.id)", main)
        selection = main[main.index("    private var iPadSelection:"):main.index("    private func prepareTab(")]
        self.assertIn("guard targetTab != shell.tab else { return }", selection)
        self.assertLess(selection.index("prepareTab(targetTab)"), selection.index("shell.tab = targetTab"))
        self.assertNotIn("navState.reset", selection)
        self.assertEqual(main.count(".safeAreaInset(edge: .bottom, spacing: 0)"), 2)

    def test_ipad_bottom_bar_is_optional_and_does_not_replace_native_tab_state(self):
        main = self.source("Orvian/App/MainTabView.swift")
        settings = self.source("Orvian/Features/Settings/SettingsView.swift")
        self.assertIn('@AppStorage("iPadTabBarAtBottom")', main)
        self.assertIn('@AppStorage("iPadTabBarAtBottom")', settings)
        self.assertIn('if iPadTabBarAtBottom {', main)
        self.assertIn('.environment(\\.iPadLayout, IPadLayout(isPad: true', main)
        self.assertIn('Toggle("Barre d’onglets en bas"', settings)
        self.assertIn('if iPadLayout.isPad', settings)

    def test_tag_details_and_settings_use_owned_navigation_state(self):
        tags = self.source("Orvian/Features/Tag/TagsView.swift")
        self.assertIn("NavigationStack(path: $padNavigation.folders)", tags)
        self.assertIn(".id(category.id)", tags)
        self.assertIn("List(selection: categorySelection)", tags)
        self.assertIn("padNavigation.select($0)", tags)
        self.assertNotIn("preferredCompactColumn", tags)
        settings = self.source("Orvian/Features/Settings/SettingsView.swift")
        self.assertIn("List(selection: $selectedSpace)", settings)
        self.assertIn("NavigationStack(path: $path)", settings)
        self.assertNotIn("stackPath", settings)
        state = self.source("Orvian/App/TabNavigationState.swift")
        self.assertIn("var settingsSelection: SettingsRoute? = .appearance", state)
        self.assertIn("var iPadTags = IPadTagNavigation()", state)

    def test_sidebar_content_respects_the_status_bar_safe_area(self):
        for name in ["Tag/TagsView", "Settings/SettingsView"]:
            with self.subTest(view=name):
                source = self.source(f"Orvian/Features/{name}.swift")
                self.assertNotIn(".ignoresSafeArea(.container, edges: .top)", source)

    def test_sidebar_header_has_readable_title_and_toolbar_sized_controls(self):
        header = self.source("Orvian/UI/PadSidebarHeader.swift")
        tags = self.source("Orvian/Features/Tag/TagsView.swift")
        self.assertIn(".font(.title2.weight(.semibold))", header)
        self.assertIn(".frame(width: 44, height: 44)", header)
        self.assertIn(".buttonStyle(.plain)", header)
        self.assertIn(".font(.body)", header)
        self.assertNotIn(".buttonStyle(.glass)", header)
        menu = tags[tags.index("PadSidebarHeader("):tags.index("if categories.isEmpty", tags.index("PadSidebarHeader("))]
        self.assertIn(".frame(width: 44, height: 44)", menu)

    def test_bar_order_matches_native_tabs_and_retains_accessible_text(self):
        bar = self.source("Orvian/UI/FloatingTabBar.swift")
        # L'ordre protégé reste Réglages — Tags — Accueil — Favoris — Profil
        # sur les deux plateformes ; la barre lit une seule liste groupée et
        # n'a plus besoin de distinguer iPad et iPhone pour l'ordre.
        self.assertIn("[.settings, .tag, .home, .favorites, .profile]", bar)
        self.assertIn("ForEach(AppTab.presentationOrder)", bar)
        self.assertNotIn("dynamicTypeSize < .accessibility1", bar)
        self.assertIn("if dynamicTypeSize.isAccessibilitySize {", bar)

    def test_profile_preserves_phone_preview_without_an_extra_pad_fetch(self):
        profile = self.source("Orvian/Features/Profile/ProfileView.swift")
        self.assertIn("ForEach(recentUploads.prefix(3))", profile)
        self.assertIn("recentUploads.prefix(iPadLayout.recentPreviewLimit)", profile)
        pad = profile[profile.index("    private var padOverview:"):profile.index("    private var recentUploadsSection:")]
        self.assertNotIn("await ", pad)
        self.assertNotIn("service.page", pad)
        self.assertIn("AnyLayout", pad)


if __name__ == "__main__":
    unittest.main()
