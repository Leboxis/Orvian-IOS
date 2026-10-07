"""Wiring assertions; async Swift behavior is exercised by macOS CI runners."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class RecentSharingWiringChecks(unittest.TestCase):
    def test_profile_and_grid_use_the_canonical_recent_source(self):
        profile = source("Orvian/Features/Profile/ProfileView.swift")
        page = source("Orvian/Features/Profile/RecentFilesView.swift")
        self.assertIn("source: RecentUploadsLoader.source", profile)
        self.assertNotIn("service.page(", profile)
        self.assertIn("sharedSource = RecentUploadsLoader.source", page)
        self.assertIn("FileGridViewModel(source: sharedSource", page)

    def test_profile_checks_drive_credential_and_request_after_await(self):
        profile = source("Orvian/Features/Profile/ProfileView.swift")
        self.assertIn("previewRequestID == requestID", profile)
        self.assertIn("session.selectedDrive?.id == drive.id", profile)
        self.assertIn("TokenStore.credentialFingerprint() == credential", profile)
        self.assertGreaterEqual(profile.count("guard isCurrentRequest() else { return }"), 4)
        self.assertIn("snapshot.items.filter { !$0.isDirectory }", profile)
        self.assertIn("ForEach(recentUploads.prefix(3))", profile)

    def test_loader_waits_for_revalidation_before_using_fresh_cache(self):
        loader = source("Orvian/Core/Cache/RecentUploadsLoader.swift")
        refresh = loader[loader.index("    func refresh("):]
        self.assertLess(refresh.index("if let inFlight"), refresh.index("Date().timeIntervalSince(cached.fetchedAt)"))
        self.assertIn("inFlight.credential == credential", refresh)
        self.assertIn("fetchedAt: requestStartedAt", refresh)
        self.assertIn("FileGridMutationCenter.shared.isSnapshotStale(", refresh)
        self.assertEqual(refresh.count("await service.page("), 1)
        self.assertIn("cursor: nil", refresh)
        self.assertNotIn("while", refresh)

    def test_disk_restore_rechecks_session_and_memory_before_store(self):
        loader = source("Orvian/Core/Cache/RecentUploadsLoader.swift")
        cached = loader[loader.index("    func cachedSnapshot("):loader.index("    func refresh(")]
        suspended = cached[cached.index("await DirectoryListStore.shared.diskSnapshot"):]
        self.assertIn("restoreGeneration == generation", suspended)
        self.assertIn("credential == TokenStore.credentialFingerprint()", suspended)
        self.assertLess(suspended.index("if let memory"), suspended.index("DirectoryListStore.shared.store("))
        self.assertLess(suspended.index("if let memory"), suspended.index("guard let disk"))

    def test_validated_head_is_separate_from_the_paginated_grid(self):
        loader = source("Orvian/Core/Cache/RecentUploadsLoader.swift")
        self.assertIn("private var firstPageByDrive: [Int: FirstPage]", loader)
        self.assertIn("first.credential == TokenStore.credentialFingerprint()", loader)
        self.assertIn("first.generation == generation", loader)
        self.assertIn("isSnapshotStale(first.snapshot", loader)
        self.assertIn("let cached = latestMemorySnapshot(driveId: driveId)", loader)
        self.assertIn("firstPageByDrive.removeAll()", loader)
        self.assertLess(loader.index("firstPageByDrive[driveId] = FirstPage("),
                        loader.index("if (existing?.items.count ?? 0) <= 12"))

    def test_scoped_runner_compiles_unmodified_production_loader(self):
        path = ROOT / ".github/scripts/check_recent_sharing.py"
        spec = importlib.util.spec_from_file_location("recent_runner", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        paths = module.sources()
        self.assertTrue(all(path.is_file() for path in paths))
        self.assertEqual(paths[1], ROOT / "Orvian/Core/Cache/RecentUploadsLoader.swift")
        self.assertIn("check=True, timeout=60", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
