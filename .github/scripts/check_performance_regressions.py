"""Keep the proven media and sorting performance regressions fixed."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


hires = source("Orvian/Core/Media/HiresImageStore.swift")
thumbnails = source("Orvian/Core/Cache/ThumbnailProvider.swift")
cards = source("Orvian/Features/Shared/FileCardView.swift")
grid = source("Orvian/Features/Shared/FileGridView.swift")
metadata = source("Orvian/Core/Media/MediaMetadataStore.swift")

assert "SharedRequests<String, ImageResult>()" in hires
assert "AsyncThrottler(maxConcurrent: 1)" in hires
assert "shouldRetry: shouldRetryThumbnail" in cards
assert "guard shouldRetry else" in thumbnails
assert "refreshCount: false" in grid
assert "guard oldServerSort != nil || newServerSort != nil" in grid
assert metadata.index("try? await Task.sleep(for: .seconds(1))") < metadata.index("let snapshot = self.entries")
load_start = metadata.index("private func ensurePersistenceLoaded() async")
load_end = metadata.index("private func scheduleSave()", load_start)
assert "Task.detached(priority: .utility)" in metadata[load_start:load_end]

print("Performance regression checks passed")
