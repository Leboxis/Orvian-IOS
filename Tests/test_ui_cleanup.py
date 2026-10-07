"""Contracts for neutral copy, folder title, and shared recent first-page wiring."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class UICleanupChecks(unittest.TestCase):
    def test_readme_has_no_provider_mentions(self):
        text = source("README.md")
        self.assertIsNone(re.search(r"kdrive|infomaniak", text, re.IGNORECASE))
        self.assertIn("À analyser", text)
        self.assertIn("licence MIT", text)

    def test_authored_user_facing_copy_is_neutral(self):
        # Only UI-authored copy, not technical class names, API addresses or comments.
        expressions = [r'\b(?:Text|Label|Link|SecureField)\("([^"\n]*)"',
                       r'\bmessage:\s*"([^"\n]*)"']
        for path in (ROOT / "Orvian/Features").rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            for expression in expressions:
                for match in re.finditer(expression, text):
                    self.assertIsNone(re.search(r"kdrive|infomaniak", match.group(1), re.IGNORECASE),
                                      str(path.relative_to(ROOT)))
        warning = source("Orvian/Core/Utils/UploadSafety.swift")
        warning = warning[warning.index("struct UploadOutcomeUnknown:"):]
        self.assertIsNone(re.search(r"kdrive|infomaniak", warning, re.IGNORECASE))
        self.assertIn("éviter un doublon", warning)

    def test_technical_api_and_setup_destination_are_preserved(self):
        api = source("Orvian/Core/API/APIClient.swift")
        self.assertIn('URL(string: "https://api.infomaniak.com")', api)
        self.assertIn('host == "api.infomaniak.com"', api)
        self.assertIn('host.hasSuffix(".upload.kdrive.infomaniak.com")', api)
        onboarding = source("Orvian/Features/Onboarding/TokenSetupView.swift")
        self.assertIn('Link("Ouvrir le portail développeur"', onboarding)
        self.assertIn('URL(string: "https://developer.infomaniak.com")', onboarding)

    def test_folder_title_removed_but_selection_and_breadcrumb_survive(self):
        folder = source("Orvian/Features/Home/DirectoryView.swift")
        self.assertNotIn("Text(crumbs.last ?? directory.name)", folder)
        self.assertEqual(folder.count("ToolbarItem(placement: .principal)"), 1)
        self.assertIn("Text(selectionTitle)", folder)
        self.assertIn('navigationTitle("")', folder)
        self.assertIn("if showBreadcrumb", folder)
        self.assertIn("folderScanner.start(driveId: driveId, directory: directory)", folder)

    def test_default_recent_reload_uses_shared_loader_only(self):
        vm = source("Orvian/Features/Shared/FileGridViewModel.swift")
        reload = vm[vm.index("    func reload("):vm.index("    /// Vraie quantité")]
        self.assertIn('source == RecentUploadsLoader.source, requestedOrderBy.isEmpty', reload)
        self.assertIn("await RecentUploadsLoader.shared.refresh(", reload)
        self.assertIn("page = (snapshot.items, snapshot.cursor, snapshot.hasMore, snapshot.fetchedAt)", reload)
        self.assertIn("fetchedAt = page.fetchedAt", reload)
        self.assertIn('let newOrder = source == RecentUploadsLoader.source && newOrderBy.isEmpty ? "asc"', reload)
        self.assertIn('order = source == RecentUploadsLoader.source && orderBy.isEmpty ? "asc"', vm)
        self.assertIn('let newDirection = source == RecentUploadsLoader.source && newOrder.isEmpty ? "asc"', vm)
        self.assertIn("memorySnapshot = RecentUploadsLoader.shared.cachedMemorySnapshot(driveId: driveId)", vm)
        self.assertIn("head.fetchedAt > fetchedAt", vm)
        more = vm[vm.index("    func loadMoreIfNeeded()"):vm.index("    /// Écrit (ou réécrit)")]
        self.assertIn("await service.page(", more)
        self.assertNotIn("RecentUploadsLoader.shared.refresh(", more)

    def test_pending_order_cannot_reuse_old_pagination_cursor(self):
        vm = source("Orvian/Features/Shared/FileGridViewModel.swift")
        reload = vm[vm.index("    func reload("):vm.index("    /// Vraie quantité")]
        self.assertIn("orderingNeedsReload = true\n                cursor = nil\n                hasMore = false", reload)
        self.assertEqual(reload.count("(!loadedOnce || orderingNeedsReload)"), 2)
        self.assertIn("orderingNeedsReload = false", reload)
        self.assertIn("guard hasMore, !orderingNeedsReload", vm)
        self.assertIn("if orderingNeedsReload || hasExpired", vm)
        commit = vm[vm.index("    private func commitListSnapshot()"):vm.index("    /// Insère immédiatement")]
        self.assertIn("guard !orderingNeedsReload, credentialFingerprint", commit)


if __name__ == "__main__":
    unittest.main()
