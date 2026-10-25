"""Nonvisual wiring contracts; the companion Swift gate exercises real async methods."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class AuditBugFixTests(unittest.TestCase):
    def test_reactivation_syncs_loaded_directory_instead_of_overwriting_its_sort(self):
        directory = source("Orvian/Features/Home/DirectoryView.swift")
        activation = directory.split(".task(id: DirectoryActivationKey(", 1)[1].split(
            ".task(id: SearchTaskKey(", 1)[0]
        self.assertIn("await viewModel.syncSort(with: filters)", activation)
        self.assertNotIn("viewModel.applySort(filters)", activation)
        self.assertLess(activation.index("syncSort"), activation.index("loadIfNeeded"))

    def test_pagination_cancels_value_captured_view_requests_on_input_changes(self):
        grid = source("Orvian/Features/Shared/FileGridView.swift")
        filters = grid.split(".onChange(of: filters)", 1)[1].split(".onChange(of: effectiveSearchText)", 1)[0]
        self.assertLess(filters.index("restartPaginationIfNeeded()"), filters.index("requiresServerReload"))
        self.assertIn(".onChange(of: effectiveSearchText) { _, _ in restartPaginationIfNeeded() }", grid)
        self.assertIn(".onChange(of: viewModel.source) { _, _ in restartPaginationIfNeeded() }", grid)
        cancellation = grid.split("private func cancelPagination()", 1)[1].split("private func restartPaginationIfNeeded()", 1)[0]
        self.assertIn("paginationTask?.cancel()", cancellation)
        self.assertIn("paginationRequestID = nil", cancellation)
        self.assertIn("paginationReplayPending = false", cancellation)

    def test_vlc_keeps_language_selection_enabled_without_prepared_captions(self):
        player = source("Orvian/Features/Viewer/VideoPlayerView.swift")
        self.assertEqual(player.count("allowsCaptions: vlcPlayback == nil || preparedSubtitles.isAvailable"), 2)
        self.assertNotIn(".disabled(vlcPlayback != nil && !preparedSubtitles.isAvailable)", player)
        menu = source("Orvian/UI/SubtitleOverlay.swift")
        languages, modes = menu.split("ForEach(SubtitleMode.allCases)", 1)
        self.assertIn("selectSource(language)", languages)
        self.assertNotIn(".disabled(", languages)
        self.assertIn(".disabled(option != .off && !allowsCaptions)", modes)

    def test_behavioral_regressions_are_wired_into_existing_checks(self):
        workflow = source(".github/workflows/checks.yml")
        self.assertIn("python3 .github/scripts/check_audit_bug_fixes.py", workflow)
        self.assertIn("python3 -m unittest discover -s Tests -p 'test_audit_bug_fixes.py'", workflow)
        self.assertNotIn("\n  push:", workflow)


if __name__ == "__main__":
    unittest.main()
