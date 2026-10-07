"""Compile production grid methods with callback-controlled offline dependencies (macOS)."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def grid_source():
    vm = (ROOT / "Orvian/Features/Shared/FileGridViewModel.swift").read_text(encoding="utf-8")
    def section(start, end):
        return vm[vm.index(start):vm.index(end)]
    methods = [
        section("    private var isCurrentSession:", "    private(set) var isReloading"),
        section("    func reload(", "    /// Écrit (ou réécrit)"),
        section("    func mergeUploaded(", "    /// Re-trie la grille"),
        section("    @discardableResult\n    func toggleFavorite", "    // MARK: - Tags"),
        section("    func updateCategories(", "    // MARK: - Suppression"),
        section("    func rename(", "    /// Déplace tous les éléments"),
        section("    func trash(_ file:", "    // MARK: - Actions de masse"),
    ]
    stubs = (ROOT / "Tests/GridMutationDependencies.swift").read_text(encoding="utf-8")
    mutation = (ROOT / "Orvian/Features/Shared/FileGridMutationCenter.swift").read_text(encoding="utf-8")
    mutation = mutation[mutation.index("enum FileGridMutation {"):mutation.index("@MainActor\nfinal class FileGridMutationCenter")]
    return stubs + "\n" + mutation + "\n@MainActor final class FileGridViewModel {\n" + """
    let credentialFingerprint = TokenStore.credentialFingerprint()
    let driveId = 7
    var source: FileSource
    var service = KDriveService()
    var items: [DriveFile] = [] { didSet { itemsRevision += 1 } }
    var itemsRevision = 0
    var dataGeneration = 0
    var confirmedMutationGeneration = 0
    var orderingNeedsReload = false
    var orderBy: [String] = []
    var order = "asc"
    var cursor: String?
    var hasMore = false
    var isLoadingMore = false
    var isReloading = false
    var isInitialLoading = false
    var loadedOnce = false
    var totalItemCount: Int?
    var errorMessage: String?
    var mutationErrorMessage: String?
    var favoriteMutationsInFlight: Set<Int> = []
    var fetchedAt = Date.distantPast
    var snapshots: [[DriveFile]] = []
    init(_ source: FileSource = .directory(1)) { self.source = source }
    func storeListSnapshot() { snapshots.append(items) }
    func flushPendingSnapshot() {}
    func resortAfterMerge() { items.sort { $0.id < $1.id } }
    func withoutSnapshot<T>(_ body: () -> T) -> T { body() }
""" + "\n".join(methods) + "\n}\n"


def main():
    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        grid = temp / "GridMutations.swift"
        grid.write_text(grid_source(), encoding="utf-8")
        output = temp / "grid-mutation-checks"
        subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                        str(grid), str(ROOT / "Orvian/Core/API/APIError.swift"),
                        str(ROOT / "Tests/GridMutationChecks.swift"), "-o", str(output)], check=True)
        subprocess.run([str(output)], check=True, timeout=60)


if __name__ == "__main__":
    main()
