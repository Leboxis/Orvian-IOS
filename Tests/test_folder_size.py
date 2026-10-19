"""kDrive folder-size API contracts; decoding/async behavior checks are Swift executables."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class FolderSizeTests(unittest.TestCase):
    def test_endpoint_matches_documented_recursive_size_api(self):
        api = json.loads(read("Api infomaniak.json"))
        operation = api["paths"]["/2/drive/{drive_id}/files/{file_id}/sizes"]["get"]
        depth = next(p for p in operation["parameters"] if p["name"] == "depth")
        self.assertIn("unlimited", depth["schema"]["enum"])
        schema = api["components"]["schemas"]["91ac10ff_CountFileSize"]
        self.assertIn("size", schema["required"])
        self.assertEqual(schema["properties"]["size"]["description"], "Total size of files")
        self.assertIn("with versions", schema["properties"]["storage_size"]["description"])
        endpoint = read("Orvian/Core/API/Endpoints.swift").split("static func directorySize(", 1)[1].split("    ///", 1)[0]
        self.assertIn('path: "/2/drive/\\(driveId)/files/\\(directoryId)/sizes"', endpoint)
        self.assertIn('URLQueryItem(name: "depth", value: "unlimited")', endpoint)

    def test_service_keeps_account_cancellation_and_missing_data_guards(self):
        service = read("Orvian/Core/API/KDriveService+Files.swift").split("func directorySize(", 1)[1].split("    ///", 1)[0]
        self.assertEqual(service.count("try Task.checkCancellation()"), 2)
        self.assertEqual(service.count("credentialFingerprint == TokenStore.credentialFingerprint()"), 2)
        self.assertIn("originatingCredential: credentialFingerprint", service)
        self.assertIn("cachePolicy: .reloadIgnoringLocalCacheData", service)
        self.assertIn("guard let size = response.data?.size else { throw APIError.invalidResponse }", service)
        self.assertNotIn("page(", service)
        self.assertNotIn("directoryContent", service)

    def test_folder_request_is_independent_and_never_uses_listing_size(self):
        model = read("Orvian/Features/Shared/FileDetailsViewModel.swift")
        self.assertIn("async let size: Void = loadFolderSize", model)
        self.assertIn("_ = await (info, tags, size)", model)
        self.assertIn("guard !isTrashed else { return }", model)
        loader = model.split("private func loadFolderSize(", 1)[1].split("private func loadInfo(", 1)[0]
        self.assertIn("guard file.isDirectory else { return }", loader)
        self.assertIn("guard isCurrent() else { return }", loader)
        self.assertNotIn("file.size", loader)
        self.assertNotIn("?? 0", loader)
        self.assertIn("folderSizeError == nil { loadedAt = Date() }", model)

    def test_details_shows_separate_loading_error_and_confirmed_total(self):
        sheet = read("Orvian/Features/Shared/FileDetailSheet.swift")
        row = sheet.split("private var folderSizeRow:", 1)[1].split("private var organization:", 1)[0]
        self.assertIn('detailRow("Poids total")', row)
        self.assertIn("model.isLoadingFolderSize", row)
        self.assertIn("else if let size = model.folderSize", row)
        self.assertIn("ByteFormatter.string(fromBytes: size)", row)
        self.assertIn("model.folderSizeError", row)
        self.assertIn("recovery(error)", row)
        self.assertIn("if isTrashed", row)
        self.assertIn("Sous-dossiers inclus, hors versions", row)
        self.assertNotIn("current.size", row)
        self.assertNotIn("size > 0", row)
        self.assertIn("if current.isDirectory { folderSizeRow }", sheet)


if __name__ == "__main__":
    unittest.main()
