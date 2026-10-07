"""Source-level UI contracts; native menu rendering requires iOS validation."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FilterMenuChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.menu = (ROOT / "Orvian/Features/Shared/FilterMenu.swift").read_text(encoding="utf-8")
        cls.model = (ROOT / "Orvian/Models/FileFilters.swift").read_text(encoding="utf-8")
        cls.classification = cls.menu.split('Section("Classification des images") {', 1)[1].split("if filters.isActive", 1)[0]

    def test_classification_uses_horizontal_native_palette(self):
        self.assertIn("Picker(selection: classificationBinding)", self.classification)
        self.assertIn(".pickerStyle(.palette)", self.classification)
        self.assertNotIn(".pickerStyle(.inline)", self.classification)
        self.assertIn("FileFilters.ClassificationFilter.allCases", self.classification)
        self.assertIn(".tag(classification)", self.classification)

    def test_short_visible_label_preserves_full_accessibility_label(self):
        self.assertIn('classification == .unscanned ? "À analyser" : classification.title', self.classification)
        self.assertIn(".accessibilityLabel(classification.title)", self.classification)
        self.assertIn('.accessibilityLabel("Classification des images")', self.classification)
        self.assertIn('case .unscanned: return "Non analysés"', self.model)

    def test_files_only_removed_from_ui_not_model(self):
        self.assertNotIn("$filters.filesOnly", self.menu)
        self.assertNotIn('Label("Fichiers uniquement"', self.menu)
        self.assertIn("var filesOnly = false", self.model)
        self.assertIn("if filesOnly {", self.model)
        self.assertIn("filters.filesOnly = false", self.menu)

    def test_all_and_full_reset_remain_available(self):
        self.assertIn("case all, sfw, nsfw, feet, unscanned", self.model)
        self.assertIn('case .all: return "Tous"', self.model)
        self.assertIn("if filters.isActive", self.menu)
        self.assertIn("filters = FileFilters()", self.menu)
        self.assertIn('Label("Réinitialiser"', self.menu)

    def test_other_filters_and_classification_coupling_remain(self):
        for marker in ["$filters.sort", "$filters.direction", "FileFilters.Orientation.allCases",
                       ".controlGroupStyle(.compactMenu)", "highResolutionBinding",
                       "FileFilters.MediaFilter.allCases", "mediaBinding"]:
            self.assertIn(marker, self.menu)
        binding = self.menu.split("private var classificationBinding:", 1)[1]
        for marker in ["filters.classification = classification", "if classification != .all",
                       "filters.media = .images", "filters.orientation = nil",
                       "filters.highResolutionVideosOnly = false"]:
            self.assertIn(marker, binding)


if __name__ == "__main__":
    unittest.main()
