"""Nonvisual wiring contracts; production Swift behavior is exercised separately."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class InterfaceRecoveryChecks(unittest.TestCase):
    def test_commands_keep_accessible_targets(self):
        toolbar = source("Orvian/Features/Shared/BrowserToolbar.swift")
        self.assertEqual(toolbar.count(".frame(minWidth: 44, minHeight: 44)"), 2)
        self.assertIn('Label("Sélectionner"', toolbar)
        self.assertIn('Label("Ouvrir un fichier au hasard"', toolbar)

    def test_intersection_uses_native_and_with_query_pagination_and_credentials(self):
        endpoint = source("Orvian/Core/API/Endpoints.swift")
        query = endpoint[endpoint.index("    static func intersectionFiles("):endpoint.index("    /// Recherche récursive")]
        self.assertIn("selection.query", query)
        self.assertIn("cursor: cursor", query)
        self.assertIn('URLQueryItem(name: "category", value: selection.categoryExpression)', query)
        selection = source("Orvian/Models/TagIntersection.swift")
        self.assertIn('joined(separator: "&")', selection)
        service = source("Orvian/Core/API/KDriveService+Files.swift")
        intersection = service[service.index("case let .intersection"):service.index("case let .directory")]
        self.assertNotIn("selection.filterPage", intersection)
        self.assertIn("CursorPage<DriveFile>.self", intersection)
        self.assertEqual(intersection.count("originatingCredential: credential"), 1)
        self.assertIn("credential == TokenStore.credentialFingerprint()", intersection)

    def test_compact_tag_navigation_uses_the_visible_stack(self):
        tags = source("Orvian/Features/Tag/TagsView.swift")
        self.assertIn("if usesTagColumns {", tags)
        self.assertIn("guard !crossState.isEditing else { return }", tags)
        self.assertIn("NavigationLink(\"Résultats\", value: CrossRoute.results)", tags)
        self.assertIn('@AppStorage("padTagsLayout")', tags)
        self.assertIn('@AppStorage("tagsLayout")', tags)
        self.assertNotIn("Afficher les résultats", tags)

    def test_inspector_threshold_never_uses_its_own_shrunken_grid(self):
        grid = source("Orvian/Features/Shared/FileGridView.swift")
        decision = grid[grid.index("    private var usesDetailsInspector:"):grid.index('@AppStorage("foldersFirstInTags")')]
        self.assertIn("iPadLayout.width", decision)
        self.assertNotIn("containerWidth", decision)
        self.assertIn("usesInspector: usesDetailsInspector", grid)
        self.assertIn("usesInspector ? nil : file", grid)

    def test_details_never_downloads_video_for_duration(self):
        details = source("Orvian/Features/Shared/FileDetailSheet.swift")
        self.assertIn("cachedInfo(driveId:", details)
        self.assertNotIn(".resolveAll(", details)
        metadata = source("Orvian/Core/Media/MediaMetadataStore.swift")
        cached = metadata[metadata.index("    func cachedInfo("):metadata.index("    func resolveAll(")]
        self.assertIn("ensurePersistenceLoaded()", cached)
        self.assertNotIn("VideoAssetCache.shared.asset", cached)
        self.assertNotIn("URLSession", cached)

    def test_phone_preferences_remain_two_or_three_with_separate_pad_density(self):
        for path in ["Orvian/Features/Shared/FileGridView.swift", "Orvian/Features/Settings/SettingsView.swift"]:
            text = source(path)
            self.assertIn("min(3, max(2, phoneColumns))", text)
            self.assertIn('@AppStorage("padFileGridDensity")', text)


if __name__ == "__main__":
    unittest.main()
