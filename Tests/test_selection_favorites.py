"""Contracts for bulk favorites in the phone selection menu and upload limits."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class SelectionFavoriteTests(unittest.TestCase):
    def test_phone_selection_menu_offers_bulk_favorites(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                text = source(path)
                self.assertIn("SelectionActionLayout {", text)
                self.assertIn("if !iPadLayout.isPad {", text)
                self.assertIn("Task { await toggleSelectedFavorites() }", text)
                self.assertIn(
                    'Label(actionableSelectionAllFavorites ? "Retirer des favoris" : "Ajouter aux favoris"',
                    text,
                )
                self.assertIn(
                    "let makeFavorite = !files.allSatisfy { $0.isFavorite == true }",
                    text,
                )

    def test_bulk_favorite_only_changes_selected_files_that_need_it(self):
        view_model = source("Orvian/Features/Shared/FileGridViewModel.swift")
        start = view_model.index("    func setFavorite(ids: Set<Int>, favorite: Bool)")
        end = view_model.index("    /// Corbeille une sélection entière", start)
        method = view_model[start:end]
        self.assertIn("ids.contains($0.id) && ($0.isFavorite ?? false) != favorite", method)
        self.assertIn("favoriteMutationsInFlight.formUnion(targets)", method)
        self.assertIn("for id in changedIDs {", method)
        self.assertIn(".favorite(driveId: driveId, fileId: id, isFavorite: favorite)", method)

    def test_upload_limits_are_shared_by_iphone_and_ipad(self):
        upload = source("Orvian/Core/API/KDriveService+Upload.swift")
        self.assertIn("static let chunkSize = 32 * 1_024 * 1_024", upload)
        self.assertIn("static let maxConcurrentChunks = 4", upload)
        self.assertIn("private static let directUploadLimit = 95 * 1_024 * 1_024", upload)
        self.assertIn("private static let uploadChunkSize = UploadChunkPipeline.chunkSize", upload)

        manager = source("Orvian/Core/Upload/UploadManager.swift")
        self.assertIn("private static let maxConcurrentUploads = 6", manager)
        self.assertIn("AsyncPermitPool(capacity: UploadManager.maxConcurrentUploads)", manager)
        # The transfer budget is not device-specific: only one limit exists.
        self.assertNotIn("iPadLayout", manager)
        self.assertNotIn("UIDevice", manager)

        add_menu = source("Orvian/Features/Shared/AddMenuButton.swift")
        self.assertIn("maxSelectionCount: 20", add_menu)


if __name__ == "__main__":
    unittest.main()
