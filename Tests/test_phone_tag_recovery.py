"""Focused source contracts for phone tag layout and selection recovery.

These contracts were rewritten when the crossed-tags screen moved from a
dedicated `crossControls` bar to the phone header button + iPad summary link.
The protective intents are unchanged: reordering must not stay active while a
cross selection is being built, the selection summary must not grow with the
length of the selected tag names, and the results screen must stay reachable
and debounced.
"""
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

    def test_both_cross_entry_points_clear_reordering_first(self):
        # Entrée par le bouton « croiser » : quitter le réarrangement avant de
        # changer de mode, sinon les cellules restent en mode déplacement.
        cross_button = section("private var crossButton:", "@ViewBuilder private var crossSummary:")
        self.assertLess(cross_button.index("isReordering = false"),
                        cross_button.index("crossState.toggleMode()"))
        # Entrée par la sélection d'un tag : le réarrangement est désactivé
        # explicitement dans les deux en-têtes (iPhone et iPad).
        for header in ("private var phoneCatalogueHeader:", "private var categoryToolbar:"):
            with self.subTest(header=header):
                self.assertIn("crossState.isEditing = false", section(header, "private var phoneCatalogueTitle:")
                              if header.startswith("private var phoneCatalogueHeader")
                              else section(header, "private var padNavigationView:"))

    def test_cross_summary_size_does_not_depend_on_selected_name_lengths(self):
        button = section("private var phoneResultsButton:", "@ToolbarContentBuilder")
        self.assertIn("crossState.selectedIDs.count", button)
        self.assertNotIn("orderedCategories.filter", button)
        self.assertNotIn(".joined(", button)
        self.assertNotIn(".map(\\.name)", button)
        self.assertNotIn("name", button)

    def test_result_navigation_and_clear_are_preserved(self):
        button = section("private var phoneResultsButton:", "@ToolbarContentBuilder")
        self.assertIn("path.append(CrossRoute.results)", button)
        self.assertIn('trail.append("Croisement de tags")', button)
        self.assertIn(".disabled(crossState.selectedIDs.isEmpty)", button)

        summary = section("@ViewBuilder private var crossSummary:", "private var intersectionResults:")
        self.assertIn('NavigationLink("Résultats", value: CrossRoute.results)', summary)

        # La liste des résultats est reconstruite dès que la sélection change,
        # après le délai anti-rafale de `DebouncedTagResults`.
        results = section("private var intersectionResults:", "private var categorySelection:")
        self.assertIn("TagIntersectionView(", results)
        self.assertIn("selection: TagIntersection(crossState.selectedIDs)", results)

        intersection = (ROOT / "Orvian/Features/Tag/TagIntersectionView.swift").read_text(encoding="utf-8")
        self.assertIn(".id(selection)", intersection)
        self.assertIn("try await Task.sleep(for: .milliseconds(180))", intersection)


if __name__ == "__main__":
    unittest.main()
