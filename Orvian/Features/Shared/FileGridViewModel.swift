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
    /// Index id → catégorie pour afficher les pastilles de tags des cartes.
    /// Il reste lié au cache partagé afin que les renommages et suppressions
    /// confirmés soient reflétés sans recharger tous les fichiers.
    var categoriesById: [Int: Category] {
        CategoryLibrary.shared.categories(for: driveId)
    }

    private var cursor: String?
    private var loadedOnce = false
    private(set) var isReloading = false
    /// Invalide toute réponse appartenant à un rechargement ou une pagination
    /// antérieur. Un ancien tri ne peut ainsi jamais remplacer le plus récent.
    private var dataGeneration = 0
    /// Tri serveur en cours (`order_by[]` + sens) : conservé pour que la
    /// pagination continue dans le même ordre que la première page.
    private var orderBy: [String] = []
    private var order = "asc"

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
    func reload(sortedBy: FileFilters? = nil) async {
        if let sortedBy {
            // Un tri serveur (dates, type, poids) remplace l'ordre par défaut
            // ; les tris restants (durée, médias, orientation) sont locaux et
            // n'exigent aucune relecture ordonnée.
            orderBy = sortedBy.serverOrderBy ?? []
            order = sortedBy.serverOrder
        }
        dataGeneration &+= 1
        let requestGeneration = dataGeneration
        let requestedOrderBy = orderBy
        let requestedOrder = order
        isLoadingMore = false
        isReloading = true
        isInitialLoading = items.isEmpty
        errorMessage = nil
        defer {
            if dataGeneration == requestGeneration {
                isReloading = false
                isInitialLoading = false
            }
        }
        do {
            async let categoriesTask: Void = CategoryLibrary.shared.ensureLoaded(for: driveId)
            let page = try await service.page(
                source,
                driveId: driveId,
                cursor: nil,
                orderBy: requestedOrderBy.isEmpty ? nil : requestedOrderBy,
                order: requestedOrder
            )
            await categoriesTask
            guard !Task.isCancelled, dataGeneration == requestGeneration else { return }
            items = filterItemsIfNeeded(page.data ?? [])
            cursor = page.cursor
            hasMore = page.hasMore ?? false
            loadedOnce = true
        } catch {
            guard !Task.isCancelled, dataGeneration == requestGeneration else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Pagination infinie : déclenché par l'apparition des dernières cartes.
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingMore, !isInitialLoading, !isReloading else { return }
        let requestGeneration = dataGeneration
        let requestedCursor = cursor
        let requestedOrderBy = orderBy
        let requestedOrder = order
        isLoadingMore = true
        // Une nouvelle demande est une tentative explicite : elle efface
        // l'erreur précédente afin que le pager et le bouton « Réessayer »
        // puissent réellement relancer la même page.
        errorMessage = nil
        defer {
            if dataGeneration == requestGeneration {
                isLoadingMore = false
            }
        }
        do {
            let page = try await service.page(
                source,
                driveId: driveId,
                cursor: requestedCursor,
                orderBy: requestedOrderBy.isEmpty ? nil : requestedOrderBy,
                order: requestedOrder
            )
            guard !Task.isCancelled, dataGeneration == requestGeneration else { return }
            let existing = Set(items.map(\.id))
            let filtered = filterItemsIfNeeded(page.data ?? [])
            items.append(contentsOf: filtered.filter { !existing.contains($0.id) })
            cursor = page.cursor
            hasMore = page.hasMore ?? false
        } catch {
            guard !Task.isCancelled, dataGeneration == requestGeneration else { return }
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
    /// Dans l'onglet Favoris, retirer l'étoile retire aussi la carte de la
    /// grille : la liste reflète alors l'état renvoyé par l'API.
    func toggleFavorite(_ file: DriveFile) async {
        guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
        let newValue = !(file.isFavorite ?? false)
        let shouldRemove = source == .favorites && !newValue
        if shouldRemove {
            items.remove(at: index)
        } else {
            items[index].isFavorite = newValue
        }
        do {
            try await service.setFavorite(driveId: driveId, fileId: file.id, favorite: newValue)
        } catch {
            if shouldRemove {
                items.insert(file, at: min(index, items.count))
            } else if let restoredIndex = items.firstIndex(where: { $0.id == file.id }) {
                items[restoredIndex].isFavorite = file.isFavorite
            }
            errorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Tags

    /// Met à jour localement les catégories (tags) d'un fichier après
    /// confirmation de l'API, pour que les pastilles des cartes suivent
    /// immédiatement (éditeur de tags et fiche détail).
    func updateCategories(for file: DriveFile, category: Category, applied: Bool) {
        applyCategoryChange(fileId: file.id, category: category, applied: applied)
    }

    /// Applique une mutation deja confirmee par une autre interface, telle que
    /// la visionneuse, sans repeter l'appel API.
    func apply(_ mutation: FileGridMutation) {
        switch mutation {
        case let .favorite(_, fileId, isFavorite):
            applyFavoriteChange(fileId: fileId, isFavorite: isFavorite)
        case let .category(_, fileId, category, applied):
            applyCategoryChange(fileId: fileId, category: category, applied: applied)
        }
    }

    private func applyFavoriteChange(fileId: Int, isFavorite: Bool) {
        guard let index = items.firstIndex(where: { $0.id == fileId }) else { return }
        if source == .favorites && !isFavorite {
            items.remove(at: index)
        } else {
            items[index].isFavorite = isFavorite
        }
    }

    private func applyCategoryChange(fileId: Int, category: Category, applied: Bool) {
        guard let index = items.firstIndex(where: { $0.id == fileId }) else { return }
        var current = items[index].categories ?? []
        if applied {
            if !current.contains(where: { $0.categoryId == category.id }) {
                current.append(FileCategory(categoryId: category.id))
            }
        } else {
            current.removeAll { $0.categoryId == category.id }
        }
        items[index].categories = current

        if case let .category(categoryId) = source,
           categoryId == category.id,
           !applied {
            items.remove(at: index)
        }
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
            if let restoredIndex = items.firstIndex(where: { $0.id == file.id }),
               items[restoredIndex].name == name {
                items[restoredIndex].name = oldName
            }
            errorMessage = "Renommage impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Change la couleur d'un dossier : mise à jour optimiste, retour arrière
    /// si l'API refuse.
    func setColor(_ file: DriveFile, color: String) async {
        guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
        let oldColor = items[index].color
        items[index].color = color
        do {
            try await service.setFolderColor(driveId: driveId, fileId: file.id, color: color)
        } catch {
            if let restoredIndex = items.firstIndex(where: { $0.id == file.id }),
               items[restoredIndex].color == color {
                items[restoredIndex].color = oldColor
            }
            errorMessage = "Couleur impossible à modifier : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
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
