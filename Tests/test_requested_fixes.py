"""Wiring checks for selected fixes; Swift behavior runs in macOS CI."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class RequestedFixChecks(unittest.TestCase):
    def test_random_uses_only_current_visible_report(self):
        for path in ["Orvian/Features/Favorites/FavoritesView.swift",
                     "Orvian/Features/Home/DirectoryView.swift"]:
            text = source(path)
            population = text[text.index("    private var playableFiles:"):]
            population = population[:population.index("\n    }")]
            self.assertIn("visibleSelectionItems.filter", population)
            self.assertNotIn("viewModel.items", population)
            self.assertNotIn("activeViewModel.items", population)
            self.assertIn("guard visibleItemsReport?.context == currentVisibleItemsContext", text)
            self.assertIn(".disabled(playableFiles.isEmpty)", text)

    def test_network_zero_is_honestly_labelled(self):
        settings = source("Orvian/Features/Settings/SettingsView.swift")
        picker = settings[settings.index('Picker("Cache réseau"'):]
        picker = picker[:picker.index("\n                }")]
        self.assertIn('Text("Désactivé sur disque").tag(0)', picker)
        self.assertNotIn('Text("Sans limite")', picker)
        self.assertIn('Text("1 Go").tag(1_024); Text("Sans limite").tag(0)', settings)
        api = source("Orvian/Core/API/APIClient.swift")
        self.assertIn("memoryCapacity: 8 * 1024 * 1024", api)
        self.assertIn("stored ?? 100", api)
        self.assertIn("désactive le cache disque", api)

    def test_cleanup_is_bound_to_origin_and_confirmation(self):
        upload = source("Orvian/Core/API/KDriveService+Upload.swift")
        chunks = upload[upload.index("    private func uploadFileInChunks("):]
        self.assertLess(chunks.index("captureUploadCredential()"), chunks.index(".startUploadSession("))
        self.assertIn("sessionToken: token, credential: credential", chunks)
        self.assertEqual(chunks.count("originatingCredential: credential.fingerprint"), 3)
        self.assertLess(chunks.index("cleanup.confirmed()"), chunks.index("return file"))
        self.assertIn("await cleanup.cancel()", chunks)
        self.assertNotIn("try? await api.sendEmpty", chunks)
        self.assertIn("finishRequested && (UploadSafety.isCancellation(error)", chunks)
        cleanup = source("Orvian/Core/Utils/UploadSessionCleanup.swift")
        self.assertIn("Task.detached", cleanup)
        self.assertNotIn("TokenStore", cleanup)
        self.assertIn("completionHandler(nil)", cleanup)

    def test_all_new_behavior_checks_run_in_existing_ci(self):
        workflow = source(".github/workflows/build.yml")
        self.assertIn("python3 .github/scripts/check_audit_regressions.py", workflow)
        runner = source(".github/scripts/check_audit_regressions.py")
        for name in ["check_grid_mutation_regressions.py", "check_tag_apply_regressions.py",
                     "check_requested_regressions.py"]:
            self.assertIn(name, runner)
            self.assertTrue((ROOT / ".github/scripts" / name).is_file())
        self.assertIn("var confirmedMutationGeneration = 0", runner)

    def test_generated_random_cache_fixtures_include_real_methods(self):
        path = ROOT / ".github/scripts/check_requested_regressions.py"
        spec = importlib.util.spec_from_file_location("requested_runner", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        generated = module.fixtures()
        self.assertEqual(generated.count("private func openRandomFile()"), 2)
        self.assertIn("static func currentCacheLimitBytes()", generated)
        self.assertEqual(generated.count("{"), generated.count("}"))
        self.assertNotIn("\\n", generated)


if __name__ == "__main__":
    unittest.main()
