import Foundation
import Observation

/// Vue-modèle partagé par toutes les grilles paginées
/// (Actualité, Fichiers, Favoris, Média).
@MainActor
@Observable
final class FileGridViewModel {
    private(set) var items: [DriveFile] = []
    private(set) var isInitialLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    /// Index id → catégorie pour afficher les pastilles de tags des cartes
    /// (les listes ne renvoient que des `categoryId`).
    private(set) var categoriesById: [Int: Category] = [:]

    private var cursor: String?
    private var loadedOnce = false

    let source: FileSource
    let driveId: Int
    private let service: KDriveService

    init(source: FileSource, driveId: Int, service: KDriveService = KDriveService()) {
        self.source = source
        self.driveId = driveId
        self.service = service
    }

    // MARK: - Chargement

    /// Charge au premier affichage de l'onglet uniquement.
    func loadIfNeeded() async {
        guard !loadedOnce, !isInitialLoading else { return }
        await reload()
    }

    /// Rafraîchit en conservant les anciennes cartes à l'écran.
    func reload() async {
        isInitialLoading = items.isEmpty
        errorMessage = nil
        do {
            async let categoriesTask: Void = CategoryLibrary.shared.ensureLoaded(for: driveId)
            let page = try await service.page(source, driveId: driveId, cursor: nil)
            await categoriesTask
            guard !Task.isCancelled else { return }
            categoriesById = CategoryLibrary.shared.categories(for: driveId)
            items = filterItemsIfNeeded(page.data ?? [])
            cursor = page.cursor
            hasMore = page.hasMore ?? false
            loadedOnce = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        isInitialLoading = false
    }

    /// Pagination infinie : déclenché par l'apparition des dernières cartes.
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingMore, !isInitialLoading, errorMessage == nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.page(source, driveId: driveId, cursor: cursor)
            guard !Task.isCancelled else { return }
            let existing = Set(items.map(\.id))
            let filtered = filterItemsIfNeeded(page.data ?? [])
            items.append(contentsOf: filtered.filter { !existing.contains($0.id) })
            cursor = page.cursor
            hasMore = page.hasMore ?? false
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func filterItemsIfNeeded(_ raw: [DriveFile]) -> [DriveFile] {
        switch source {
        case .recents, .mostViewed:
            return raw.filter { !$0.isDirectory }
        default:
            return raw
        }
    }

    /// Insère immédiatement les fichiers confirmés par la réponse d'upload.
    /// Cela masque le léger délai possible de l'index du dossier côté serveur,
    /// sans déclencher plusieurs rechargements réseau successifs.
    func mergeUploaded(_ uploadedFiles: [DriveFile]) {
        guard !uploadedFiles.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        // La réponse d'upload n'annonce pas toujours les dates ; les compléter
        // avec l'instant de l'import garantit qu'un tri « Date d'importation »
        // ou « Date de modification » place le fichier fraîchement uploadé
        // tout en haut au lieu de le reléguer hors de la première page.
        let merged = uploadedFiles.map { file -> DriveFile in
            var file = file
            if file.addedAt == nil { file.addedAt = now }
            if file.lastModifiedAt == nil { file.lastModifiedAt = now }
            return file
        }
        let uploadedIDs = Set(merged.map(\.id))
        items.removeAll { uploadedIDs.contains($0.id) }
        items.append(contentsOf: merged)
        items.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Favoris

    /// Bascule optimiste : l'étoile change immédiatement, retour arrière si l'API refuse.
    func toggleFavorite(_ file: DriveFile) async {
        guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
        let newValue = !(file.isFavorite ?? false)
        items[index].isFavorite = newValue
        do {
            try await service.setFavorite(driveId: driveId, fileId: file.id, favorite: newValue)
        } catch {
            items[index].isFavorite = file.isFavorite
            errorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Tags

    /// Met à jour localement les catégories (tags) d'un fichier après
    /// confirmation de l'API, pour que les pastilles des cartes suivent
    /// immédiatement (éditeur de tags et fiche détail).
    func updateCategories(for file: DriveFile, category: Category, applied: Bool) {
        guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
        var current = items[index].categories ?? []
        if applied {
            if !current.contains(where: { $0.categoryId == category.id }) {
                current.append(FileCategory(categoryId: category.id))
            }
        } else {
            current.removeAll { $0.categoryId == category.id }
        }
        items[index].categories = current
    }

    // MARK: - Suppression, renommage & déplacement

    func trash(_ file: DriveFile) async {
        do {
            try await service.trash(driveId: driveId, fileId: file.id)
            items.removeAll { $0.id == file.id }
        } catch {
            errorMessage = "Suppression impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Corbeille une sélection entière ; les échecs partiels sont signalés
    /// dans `errorMessage` sans bloquer les autres suppressions.
    @discardableResult
    func trash(ids: Set<Int>) async -> Set<Int> {
        errorMessage = nil
        var trashedIDs: Set<Int> = []
        var firstError: Error?

        for id in ids {
            do {
                try await service.trash(driveId: driveId, fileId: id)
                trashedIDs.insert(id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        items.removeAll { trashedIDs.contains($0.id) }

        if let firstError {
            let failedCount = ids.count - trashedIDs.count
            let detail = (firstError as? APIError)?.errorDescription ?? firstError.localizedDescription
            errorMessage = failedCount == 1
                ? "Un élément n’a pas pu être supprimé : \(detail)"
                : "\(failedCount) éléments n’ont pas pu être supprimés : \(detail)"
        }

        return trashedIDs
    }

    func rename(_ file: DriveFile, name: String) async {
        guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
        let oldName = items[index].name
        items[index].name = name
        do {
            try await service.rename(driveId: driveId, fileId: file.id, name: name)
        } catch {
            items[index].name = oldName
            errorMessage = "Renommage impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Déplace tous les éléments demandés. Les réussites disparaissent
    /// immédiatement de la grille ; les éventuels échecs restent affichés.
    @discardableResult
    func move(ids: Set<Int>, to destinationDirectoryId: Int) async -> Set<Int> {
        errorMessage = nil
        var movedIDs: Set<Int> = []
        var firstError: Error?

        for id in ids {
            do {
                try await service.move(
                    driveId: driveId,
                    fileId: id,
                    destinationDirectoryId: destinationDirectoryId
                )
                movedIDs.insert(id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        items.removeAll { movedIDs.contains($0.id) }

        if let firstError {
            let failedCount = ids.count - movedIDs.count
            let detail = (firstError as? APIError)?.errorDescription ?? firstError.localizedDescription
            errorMessage = failedCount == 1
                ? "Un élément n’a pas pu être déplacé : \(detail)"
                : "\(failedCount) éléments n’ont pas pu être déplacés : \(detail)"
        }

        return movedIDs
    }

    // MARK: - Corbeille

    /// Supprime définitivement un fichier de la corbeille.
    func permanentlyDelete(_ file: DriveFile) async {
        do {
            try await service.permanentlyDelete(driveId: driveId, fileId: file.id)
            items.removeAll { $0.id == file.id }
        } catch {
            errorMessage = "Suppression définitive impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Supprime définitivement une sélection entière ; les échecs partiels
    /// sont signalés dans `errorMessage` sans bloquer les autres suppressions.
    func permanentlyDelete(ids: Set<Int>) async {
        var firstError: Error?
        var deletedIds: Set<Int> = []
        for id in ids {
            do {
                try await service.permanentlyDelete(driveId: driveId, fileId: id)
                deletedIds.insert(id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        items.removeAll { deletedIds.contains($0.id) }
        if let firstError {
            errorMessage = "Suppression définitive impossible : \((firstError as? APIError)?.errorDescription ?? firstError.localizedDescription)"
        }
    }

    /// Restaure un fichier de la corbeille vers son dossier d'origine ; si ce
    /// dossier n'existe plus, retente vers la racine du drive (id 1).
    func restore(_ file: DriveFile) async -> Bool {
        let destination = file.parentId ?? 1
        do {
            try await service.restore(driveId: driveId, fileId: file.id, destinationDirectoryId: destination)
            items.removeAll { $0.id == file.id }
            return true
        } catch {
            guard destination != 1 else {
                errorMessage = "Restauration impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
                return false
            }
            do {
                try await service.restore(driveId: driveId, fileId: file.id, destinationDirectoryId: 1)
                items.removeAll { $0.id == file.id }
                return true
            } catch {
                errorMessage = "Restauration impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
                return false
            }
        }
    }

    /// Restaure une sélection entière de la corbeille ; les échecs partiels
    /// sont signalés dans `errorMessage` sans bloquer les autres restaurations.
    @discardableResult
    func restore(ids: Set<Int>) async -> Set<Int> {
        errorMessage = nil
        var restoredIDs: Set<Int> = []
        var firstError: Error?

        for id in ids {
            let destination = items.first(where: { $0.id == id })?.parentId ?? 1
            do {
                do {
                    try await service.restore(driveId: driveId, fileId: id, destinationDirectoryId: destination)
                } catch {
                    guard destination != 1 else { throw error }
                    try await service.restore(driveId: driveId, fileId: id, destinationDirectoryId: 1)
                }
                restoredIDs.insert(id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        items.removeAll { restoredIDs.contains($0.id) }

        if let firstError {
            let failedCount = ids.count - restoredIDs.count
            let detail = (firstError as? APIError)?.errorDescription ?? firstError.localizedDescription
            errorMessage = failedCount == 1
                ? "Un élément n’a pas pu être restauré : \(detail)"
                : "\(failedCount) éléments n’ont pas pu être restaurés : \(detail)"
        }

        return restoredIDs
    }

    // MARK: - Groupes (Actualité par jour, Média par mois)

    struct Group: Identifiable {
        let title: String
        let files: [DriveFile]
        var id: String { title }
    }

    func groups(calendar: Calendar = .current, by component: Calendar.Component, title: (Date) -> String) -> [Group] {
        var buckets: [(Date, [DriveFile])] = []
        for file in items {
            let date = Date(timeIntervalSince1970: file.lastModifiedAt ?? file.addedAt ?? 0)
            if let last = buckets.last, calendar.isDate(last.0, equalTo: date, toGranularity: component) {
                buckets[buckets.count - 1].1.append(file)
            } else {
                buckets.append((date, [file]))
            }
        }
        return buckets.map { Group(title: title($0.0), files: $0.1) }
    }
}
