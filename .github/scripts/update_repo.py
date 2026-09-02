"""Regenerates the LiveContainer source catalog, retaining the latest versions."""
import json
import sys
from pathlib import Path
from typing import Any

REPO = "Leboxis/Orvian-IOS"
ICON = "https://raw.githubusercontent.com/Leboxis/Orvian-IOS/refs/heads/main/Orvian/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
MAX_VERSIONS = 3


def make_version(version: str, tag: str, size: str, version_date: str) -> dict[str, Any]:
    return {
        "version": version,
        "date": version_date,
        "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/Orvian-{version}-unsigned.ipa",
        "size": int(size),
    }


def read_previous_versions(catalog_path: Path) -> list[dict[str, Any]]:
    """Reads the existing source, including the pre-history flat format."""
    try:
        source = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return []

    apps = source.get("apps")
    if not isinstance(apps, list):
        return []

    for app in apps:
        if not isinstance(app, dict) or app.get("bundleIdentifier") != "com.orvian.app":
            continue

        versions = app.get("versions")
        if isinstance(versions, list):
            return [entry for entry in versions if isinstance(entry, dict)]

        # Migration from the old format, where the version lived directly on
        # the app object rather than in its version history.
        if isinstance(app.get("version"), str):
            keys = ("version", "date", "downloadURL", "size")
            return [{key: app[key] for key in keys if key in app}]

    return []


def keep_latest_versions(
    current: dict[str, Any], previous: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    versions: list[dict[str, Any]] = []
    seen_versions: set[str] = set()

    for entry in [current, *previous]:
        version = entry.get("version")
        if not isinstance(version, str) or version in seen_versions:
            continue
        versions.append(entry)
        seen_versions.add(version)
        if len(versions) == MAX_VERSIONS:
            break

    return versions


def main() -> int:
    if len(sys.argv) != 7:
        print(
            "Usage: update_repo.py VERSION TAG SIZE DATE NOTES EXISTING_CATALOG",
            file=sys.stderr,
        )
        return 2

    version, tag, size, version_date, _notes, existing_catalog = sys.argv[1:7]
    current = make_version(version, tag, size, version_date)
    versions = keep_latest_versions(current, read_previous_versions(Path(existing_catalog)))

    source = {
        "name": "Orvian",
        "identifier": "com.orvian.repo",
        "tintColor": "#4285F5",
        "iconURL": ICON,
        "apps": [
            {
                "name": "Orvian",
                "bundleIdentifier": "com.orvian.app",
                "iconURL": ICON,
                "tintColor": "#4285F5",
                "category": "utilities",
                "versions": versions,
            }
        ],
    }
    json.dump(source, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
