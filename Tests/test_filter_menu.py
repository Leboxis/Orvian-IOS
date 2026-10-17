"""Source-level UI contracts; native menu rendering requires iOS validation."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FilterMenuChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.menu = (ROOT / "Orvian/Features/Shared/FilterMenu.swift").read_text(encoding="utf-8")
        cls.model = (ROOT / "Orvian/Models/FileFilters.swift").read_text(encoding="utf-8")

    def test_no_classification_filter_remains(self):
        for source in (self.menu, self.model):
            self.assertNotIn("Classification", source)
            self.assertNotIn("classification", source)
            self.assertNotIn("sfw", source)
            self.assertNotIn("nsfw", source)

    def test_files_only_removed_from_ui_not_model(self):
        self.assertNotIn("$filters.filesOnly", self.menu)
        self.assertNotIn('Label("Fichiers uniquement"', self.menu)
        self.assertIn("var filesOnly = false", self.model)
        self.assertIn("if filesOnly {", self.model)
        self.assertIn("filters.filesOnly = false", self.menu)

    def test_full_reset_remains_available(self):
        self.assertIn("if filters.isActive", self.menu)
        self.assertIn("filters = FileFilters()", self.menu)
        self.assertIn('Label("Réinitialiser"', self.menu)

    def test_other_filters_remain(self):
        for marker in ["$filters.sort", "$filters.direction", "FileFilters.Orientation.allCases",
                       ".controlGroupStyle(.compactMenu)", "highResolutionBinding",
                       "FileFilters.MediaFilter.allCases", "mediaBinding"]:
            self.assertIn(marker, self.menu)


if __name__ == "__main__":
    unittest.main()