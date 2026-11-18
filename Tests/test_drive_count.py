"""kDrive drive-wide file count contracts; decoding/async behavior checks are Swift executables."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class DriveCountTests(unittest.TestCase):
    def test_endpoint_matches_documented_recursive_count_api(self):
        api = json.loads(read("Api infomaniak.json"))
        operation = api["paths"]["/3/drive/{drive_id}/files/{file_id}/count"]["get"]
        depth = next(p for p in operation["parameters"] if p["name"] == "depth")
        self.assertIn("unlimited", depth["schema"]["enum"])
        schema = api["components"]["schemas"]["91ac10ff_CountFile"]
        for field in ("count", "files", "directories"):
            self.assertIn(field, schema["required"])
        endpoint = read("Orvian/Core/API/Endpoints.swift").split("static func driveCount(", 1)[1].split("    ///", 1)[0]
        self.assertIn('path: "/3/drive/\\(driveId)/files/1/count"', endpoint)
        self.assertIn('URLQueryItem(name: "depth", value: "unlimited")', endpoint)

    def test_service_returns_full_count_and_guards_missing_data(self):
        service = read("Orvian/Core/API/KDriveService+Files.swift").split("func driveCount(", 1)[1]
        self.assertIn("DataResponse<DirectoryCount>.self", service)
        self.assertIn(".driveCount(driveId: driveId)", service)
        self.assertIn("cachePolicy: .reloadIgnoringLocalCacheData", service)
        self.assertIn("guard let data = wrapper.data else { throw APIError.invalidResponse }", service)
        self.assertNotIn("page(", service)

    def test_settings_storage_space_displays_drive_file_count(self):
        settings = read("Orvian/Features/Settings/SettingsView.swift")
        space = settings.split("private struct StorageSpace", 1)[1]
        self.assertIn('Section("Contenu du drive")', space)
        self.assertIn("counts.files", space)
        self.assertIn("counts.directories", space)
        self.assertIn("onRefreshDriveCounts", space)
        self.assertIn("driveCounts: driveCounts", settings)
        summary = settings.split("private var storageSummary", 1)[1].split("private var securitySummary", 1)[0]
        self.assertIn("driveCounts?.files", summary)
        task = settings.split(".task(id: session.selectedDrive?.id)", 1)[1].split(".onChange(", 1)[0]
        self.assertIn("await loadDriveCounts()", task)


if __name__ == "__main__":
    unittest.main()
