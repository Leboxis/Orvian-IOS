"""Keep the proven media and sorting performance regressions fixed."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


hires = source("Orvian/Core/Media/HiresImageStore.swift")
thumbnails = source("Orvian/Core/Cache/ThumbnailProvider.swift")
ledger = source("Orvian/Core/Cache/ThumbnailFailureLedger.swift")
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

# Cache des miniatures : la lecture locale (mémoire puis disque) précède le
# réseau, l'écriture disque n'a lieu qu'après validation du contenu, et le
# cache négatif ne peut jamais masquer une entrée disque.
assert "if let image = await loadFromDisk(key)" in thumbnails
assert thumbnails.index("await loadFromDisk(key)") < thumbnails.index("return await fetch(key: key)")
assert "private nonisolated func decodeAndStore" in thumbnails
assert thumbnails.index("guard let image = UIImage.decode(data)") < thumbnails.index("disk.store(")
assert "private var failures = ThumbnailFailureLedger()" in thumbnails
assert "isBlocked(key.nsString as String), !hasDiskEntry(key)" in thumbnails
assert "private func hasDiskEntry(_ key: Key) -> Bool" in thumbnails
assert "recentFailures" not in thumbnails, "Le cache négatif doit passer par ThumbnailFailureLedger"
assert "recentFailures" not in thumbnails, "Le cache négatif doit passer par ThumbnailFailureLedger"
assert "failures.markAbsent(" in thumbnails and "failures.markTransientFailure(" in thumbnails
assert "recordFailure(.absent, for: key)" in thumbnails
assert thumbnails.index("guard let apiError = error as? APIError") < thumbnails.index("return .absent")
assert "let absenceTTL" in ledger and "let transientTTL" in ledger and "let limit: Int" in ledger
assert "markAbsent" in ledger and "markTransientFailure" in ledger and "mutating func clear" in ledger
assert "markAbsent" in ledger and "markTransientFailure" in ledger and "func clear" in ledger

print("Performance regression checks passed")
