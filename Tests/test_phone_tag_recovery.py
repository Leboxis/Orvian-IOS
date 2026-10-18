"""Focused source contracts for phone tag layout and selection recovery."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
TAGS = (ROOT / "Orvian/Features/Tag/TagsView.swift").read_text(encoding="utf-8")


def section(start, end):
    return TAGS[TAGS.index(start):TAGS.index(end, TAGS.index(start))]


class PhoneTagRecoveryTests(unittest.TestCase):
    def test_category_rows_wrap_and_grow_for_accessibility(self):
        row = section("private struct CategoryRow:", "struct TagGridCard:")
        self.assertIn("@Environment(\\.dynamicTypeSize)", row)
        self.assertIn(".lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)", row)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", row)
        self.assertNotIn(".lineLimit(1)", row)

    def test_grid_titles_wrap_including_compact_accessibility_cards(self):
        card = section("struct TagGridCard:", "enum CategoryLayout:")
        self.assertIn("@Environment(\\.dynamicTypeSize)", card)
        self.assertIn(".lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : (compact ? 1 : 2))", card)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", card)
        self.assertIn("CardNameLayout {", card)
        self.assertNotIn(".clipped()", card)
        columns = section("private var gridColumns:", "private var list:")
        self.assertIn("dynamicTypeSize.isAccessibilitySize ? 1", columns)

    def test_phone_reordering_is_blocked_during_active_cross_selection(self):
        toolbar = section("private var categoryToolbar:", "private var padNavigationView:")
        self.assertIn(".disabled(crossState.isActive)", toolbar)
        self.assertNotIn(".disabled(iPadLayout.isPad && crossState.isActive)", toolbar)
        self.assertIn("guard !crossState.isActive else { return }", toolbar)

    def test_both_cross_editing_entry_points_clear_reordering_first(self):
        cross_button = section("private var crossButton:", "@ViewBuilder private var crossSummary:")
        self.assertLess(cross_button.index("isReordering = false"),
                        cross_button.index("crossState.toggleMode()"))
        controls = section("@ViewBuilder private var crossControls:", "private var intersectionResults:")
        self.assertLess(controls.index("isReordering = false"),
                        controls.index("crossState.isEditing.toggle()"))

    def test_cross_summary_size_does_not_depend_on_selected_name_lengths(self):
        controls = section("@ViewBuilder private var crossControls:", "private var intersectionResults:")
        self.assertIn("crossState.selectedIDs.count", controls)
        self.assertNotIn("orderedCategories.filter", controls)
        self.assertNotIn(".joined(", controls)
        self.assertNotIn(".map(\\.name)", controls)

    def test_finish_clear_and_result_navigation_are_preserved(self):
        controls = section("@ViewBuilder private var crossControls:", "private var intersectionResults:")
        self.assertIn('Button(crossState.isEditing ? "Terminer" : "Modifier")', controls)
        self.assertIn("let wasEditing = crossState.isEditing", controls)
        self.assertIn("if wasEditing && !crossState.selectedIDs.isEmpty", controls)
        self.assertIn('path.append(CrossRoute.results); trail = ["Croisement de tags"]', controls)
        self.assertIn('Button("Effacer")', controls)
        self.assertIn("crossState.clear()", controls)
        self.assertIn("path = NavigationPath(); trail = []", controls)
        summary = section("@ViewBuilder private var crossSummary:", "@ViewBuilder private var crossControls:")
        self.assertIn('NavigationLink("Résultats", value: CrossRoute.results)', summary)
        results = section("private var intersectionResults:", "private var categorySelection:")
        self.assertIn(".safeAreaInset(edge: .top)", results)
        self.assertIn("crossControls", results)


if __name__ == "__main__":
    unittest.main()
