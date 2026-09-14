import Foundation

@main
struct FavoritesDiskCacheChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FavoritesDiskCache(directory: directory)
        var file = DriveFile.root(name: "Favori enregistré")
        file.isFavorite = true
        file.categories = [FileCategory(categoryId: 42)]
        let date = Date(timeIntervalSinceNow: -120)
        let snapshot = DirectoryListSnapshot(items: [file], cursor: "next", hasMore: true,
                                             totalItemCount: nil, orderBy: ["name"], order: "asc", fetchedAt: date)
        cache.store(snapshot, key: "account-a|drive-1")
        let saved = await cache.snapshot(key: "account-a|drive-1")
        precondition(saved?.items == [file], "Files and tags must survive JSON coding")
        precondition(saved?.cursor == "next" && saved?.hasMore == true, "Pagination must survive")
        precondition(saved?.fetchedAt == date, "Local writes must not renew network freshness")
        let reopened = FavoritesDiskCache(directory: directory)
        let restored = await reopened.snapshot(key: "account-a|drive-1")
        precondition(restored?.items == [file], "A new cache instance must restore persisted files")
        let otherAccount = await cache.snapshot(key: "account-b|drive-1")
        precondition(otherAccount == nil, "Accounts must be isolated")
        let otherDrive = await cache.snapshot(key: "account-a|drive-2")
        precondition(otherDrive == nil, "Drives must be isolated")
        var expired = snapshot
        expired.fetchedAt = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
        cache.store(expired, key: "expired")
        let old = await cache.snapshot(key: "expired")
        precondition(old == nil, "Expired data must be discarded")
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in urls { try Data("broken JSON".utf8).write(to: url) }
        let corrupt = await cache.snapshot(key: "account-a|drive-1")
        precondition(corrupt == nil, "Corruption must fall back to the network")
        cache.store(snapshot, key: "account-a|drive-1")
        cache.clear()
        let cleared = await cache.snapshot(key: "account-a|drive-1")
        precondition(cleared == nil, "Logout must remove even pending writes")

        // Contrôles statiques des mutations qui doivent aussi invalider les
        // snapshots de grilles démontées. Ils tournent dans le même job CI que
        // le cache disque et évitent de dépendre de SwiftUI pour cette garde.
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func productionSource(_ relativePath: String) throws -> String {
            try String(
                contentsOf: projectRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }
        let mutationCenterSource = try productionSource("Orvian/Features/Shared/FileGridMutationCenter.swift")
        let viewModelSource = try productionSource("Orvian/Features/Shared/FileGridViewModel.swift")
        let gridSource = try productionSource("Orvian/Features/Shared/FileGridView.swift")
        let detailSource = try productionSource("Orvian/Features/Shared/FileDetailSheet.swift")
        let tagsEditorSource = try productionSource("Orvian/Features/Shared/TagsEditorSheet.swift")

        precondition(mutationCenterSource.contains("case rename(driveId:"))
        precondition(mutationCenterSource.contains("case color(driveId:"))
        precondition(mutationCenterSource.contains("case trashed(driveId:"))
        precondition(mutationCenterSource.contains("func isSnapshotStale("))
        precondition(mutationCenterSource.contains("!isReflected(record.mutation"),
                     "Cache invalidation must be targeted to snapshots that still carry stale state")
        precondition(viewModelSource.contains("FileGridMutationCenter.shared.isSnapshotStale("),
                     "Unmounted grids must reject stale snapshots before the 60-second freshness window")
        precondition(viewModelSource.contains("let currentSnapshot = DirectoryListSnapshot("),
                     "A retained view model must detect mutations missed while its view was unmounted")

        func requireConfirmedPublication(
            in functionSource: Substring,
            apiCall: String,
            mutation: String
        ) {
            guard let api = functionSource.range(of: apiCall),
                  let publication = functionSource.range(of: mutation),
                  let failure = functionSource.range(of: "} catch {") else {
                preconditionFailure("Missing API, mutation publication, or rollback branch")
            }
            precondition(api.lowerBound < publication.lowerBound && publication.lowerBound < failure.lowerBound,
                         "Mutations must be published only after server confirmation")
        }
        func functionBody(startingAt marker: String, endingAt endMarker: String) -> Substring {
            guard let start = viewModelSource.range(of: marker)?.lowerBound,
                  let end = viewModelSource.range(of: endMarker, range: start..<viewModelSource.endIndex)?.lowerBound else {
                preconditionFailure("Missing mutation function markers")
            }
            return viewModelSource[start..<end]
        }

        requireConfirmedPublication(
            in: functionBody(startingAt: "func toggleFavorite(", endingAt: "// MARK: - Tags"),
            apiCall: "try await service.setFavorite(",
            mutation: ".favorite(driveId:"
        )
        requireConfirmedPublication(
            in: functionBody(startingAt: "func rename(", endingAt: "/// Change la couleur"),
            apiCall: "try await service.rename(",
            mutation: ".rename(driveId:"
        )
        requireConfirmedPublication(
            in: functionBody(startingAt: "func setColor(", endingAt: "/// Déplace tous"),
            apiCall: "try await service.setFolderColor(",
            mutation: ".color(driveId:"
        )
        let singleTrash = functionBody(startingAt: "func trash(_ file:", endingAt: "// MARK: - Actions de masse")
        requireConfirmedPublication(
            in: singleTrash,
            apiCall: "try await service.trash(",
            mutation: ".trashed(driveId:"
        )

        let categoryUpdate = functionBody(startingAt: "func updateCategories(", endingAt: "/// Applique une mutation")
        precondition(!categoryUpdate.contains("service.addCategory") && !categoryUpdate.contains("service.removeCategory"),
                     "TagsEditorSheet alone must execute the category API")
        precondition(categoryUpdate.components(separatedBy: "FileGridMutationCenter.shared.publish(").count == 2,
                     "A confirmed category change must be published exactly once")
        precondition(!tagsEditorSource.contains("FileGridMutationCenter.shared.publish("),
                     "TagsEditorSheet must report success without publishing a second mutation")
        guard let addCategory = tagsEditorSource.range(of: "try await service.addCategory("),
              let removeCategory = tagsEditorSource.range(of: "try await service.removeCategory("),
              let onChanged = tagsEditorSource.range(of: "onChanged?(category, isApplying)") else {
            preconditionFailure("TagsEditorSheet confirmation flow is missing")
        }
        precondition(addCategory.lowerBound < onChanged.lowerBound && removeCategory.lowerBound < onChanged.lowerBound,
                     "Category callbacks must run only after the API succeeds")

        precondition(gridSource.contains("onToggleFavorite: { await viewModel.toggleFavorite("))
        precondition(detailSource.contains("(() async -> Bool)?"))
        precondition(!detailSource.contains("@State private var isFavorite: Bool"),
                     "FileDetailSheet must render favorite state from its parent")
        guard let favoriteAPI = viewModelSource.range(of: "try await service.setFavorite("),
              let confirmedRemoval = viewModelSource.range(
                of: "if shouldRemove {",
                range: favoriteAPI.upperBound..<viewModelSource.endIndex
              ) else {
            preconditionFailure("Favorite removal confirmation flow is missing")
        }
        precondition(favoriteAPI.lowerBound < confirmedRemoval.lowerBound,
                     "Favorites must remain presented until the server confirms removal")

        // Une entrée trop grosse ne doit pas empêcher la conservation d'une
        // petite entrée plus ancienne qui tient encore dans le budget.
        let capacityDirectory = directory.appendingPathComponent("capacity")
        let capacityCache = FavoritesDiskCache(directory: capacityDirectory)
        let now = Date()
        func seed(_ name: String, bytes: Int, age: TimeInterval) throws -> URL {
            let url = capacityDirectory.appendingPathComponent(name)
            try Data(repeating: 0, count: bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                                   ofItemAtPath: url.path)
            return url
        }
        for index in 0..<5 { _ = try seed("recent-\(index)", bytes: 1_800_000, age: Double(index + 1)) }
        let oversized = try seed("does-not-fit", bytes: 1_800_000, age: 10)
        let small = try seed("small-older", bytes: 100_000, age: 11)
        capacityCache.store(snapshot, key: "trigger")
        _ = await capacityCache.snapshot(key: "trigger") // attend aussi l'éviction sur la file série
        precondition(!FileManager.default.fileExists(atPath: oversized.path))
        precondition(FileManager.default.fileExists(atPath: small.path), "Keep smaller older entries that fit")
        print("Favorites disk cache checks passed")
    }
}
