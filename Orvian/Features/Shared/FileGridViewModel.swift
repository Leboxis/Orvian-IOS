import Foundation
import Observation

/// Vue-modèle partagé par toutes les grilles paginées
/// (Actualité, Fichiers, Favoris, Média).
@MainActor
@Observable
final class FileGridViewModel {
    private(set) var items: [DriveFile] = [] {
        didSet {
            // Version incrémentale du contenu : les clés de mémoïsation des
            // vues (cache des filtres, tâches de pagination et de métadonnées)
            // s'appuient sur ce compteur au lieu de relire tout le tableau à
            // chaque rendu — un coût O(n) par frame sur les très grandes
            // listes. Toute mutation passe ici, y compris la modification
            // d'un élément (nom, favori, couleur, tags), le tri ou l'ajout
            // paginé, car un tableau valeur est réécrit en entier.
            itemsRevision &+= 1
            // Les mutations locales (corbeille, déplacement, import, favoris,
            // renommage…) resynchronisent l'entrée de cache : une réouverture
            // de la liste affiche immédiatement l'état à jour.
            if loadedOnce {
                storeListSnapshot()
            }
        }
    }
    /// Compteur incrémenté à chaque mutation de `items`.
    private(set) var itemsRevision = 0
    private(set) var isInitialLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    /// Nombre total d'éléments renvoyé par le serveur (première page).
    /// `nil` tant que le chargement n'a pas eu lieu ou si le endpoint
    /// ne fournit pas cette information.
    private(set) var totalItemCount: Int?
    private(set) var errorMessage: String?
    /// Erreurs des opérations de mutation (favoris, corbeille, restauration,
    /// déplacement, renommage, couleur) : séparées de `errorMessage` (chargement
    /// et pagination) pour que l'UI affiche une alerte dédiée au lieu du
    /// bouton « Réessayer » réservé à la pagination.
    private(set) var mutationErrorMessage: String?
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

    /// Charge au premier affichage de l'onglet uniquement. Si une liste
    /// déjà consultée figure dans le cache mémoire, elle est affichée
    /// immédiatement (contenu, pagination et compteur) pendant que le
    /// réseau revalide en arrière-plan : la réouverture d'un dossier ne
    /// repasse plus par le squelette ni par un aller-retour bloquant.
    func loadIfNeeded() async {
        guard !loadedOnce, !isInitialLoading else { return }
        if let snapshot = DirectoryListStore.shared.snapshot(
            source: source,
            driveId: driveId,
            orderBy: orderBy,
            order: order
        ) {
            // L'ordre des affectations importe : `items` en dernier déclenche
            // la resynchronisation du cache avec un état déjà complet.
            orderBy = snapshot.orderBy
            order = snapshot.order
            cursor = snapshot.cursor
            hasMore = snapshot.hasMore
            totalItemCount = snapshot.totalItemCount
            loadedOnce = true
            items = snapshot.items
            // Revalidation silencieuse : les cartes restent affichées et
            // l'ETag renvoie 304 (quelques octets) si rien n'a changé.
            Task { await reload() }
            return
        }
        await reload()
    }

    /// Efface l'erreur de mutation après sa présentation à l'utilisateur.
    func clearMutationError() {
        mutationErrorMessage = nil
    }

    /// Rafraîchit en conservant les anciennes cartes à l'écran.
    ///
    /// `forceNetwork` (pull-to-refresh, changement de tri, rafraîchissement
    /// post-mutation) impose une lecture réseau sans cache HTTP. Sans lui,
    /// la revalidation ETag/304 sert la liste inchangée en quelques octets.
    func reload(sortedBy: FileFilters? = nil, forceNetwork: Bool = false) async {
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
            // Le compteur part en même temps que la page : la durée perçue
            // est le max des deux allers-retours au lieu de leur somme, et
            // le badge « N éléments » n'attend plus la fin de la liste.
            async let countTask: Int? = fetchDirectoryCount()
            let page = try await service.page(
                source,
                driveId: driveId,
                cursor: nil,
                orderBy: requestedOrderBy.isEmpty ? nil : requestedOrderBy,
                order: requestedOrder,
                forceNetwork: forceNetwork
            )
            let freshCount = await countTask
            await categoriesTask
            guard !Task.isCancelled, dataGeneration == requestGeneration else { return }
            // Curseur et compteur d'abord, items en dernier : la sauvegarde
            // déclenchée par `didSet` capture toujours un état cohérent.
            cursor = page.cursor
            hasMore = page.hasMore ?? false
            totalItemCount = freshCount
            loadedOnce = true
            items = filterItemsIfNeeded(page.data ?? [])
            storeListSnapshot()
        } catch {
            guard !Task.isCancelled, dataGeneration == requestGeneration else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Vraie quantité d'un dossier via l'endpoint `count` dédié (les listes
    /// paginées n'exposent pas de total). Sans résultat, `nil` : le compteur
    /// affiché retombe sur les éléments chargés ou conserve l'ancienne valeur.
    private func fetchDirectoryCount() async -> Int? {
        guard case let .directory(directoryId) = source else { return nil }
        return try? await service.directoryCount(driveId: driveId, directoryId: directoryId)
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
            let appended = filtered.filter { !existing.contains($0.id) }
            // Même invariant que dans `reload` : cursor/hasMore d'abord,
            // items ensuite, pour que le snapshot issu de `didSet` capture
            // la pagination à jour avec les nouvelles cartes.
            cursor = page.cursor
            hasMore = page.hasMore ?? false
            items.append(contentsOf: appended)
        } catch {
            guard !Task.isCancelled, dataGeneration == requestGeneration else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func filterItemsIfNeeded(_ raw: [DriveFile]) -> [DriveFile] {
        switch source {
        case .recents:
            return raw.filter { !$0.isDirectory }
        default:
            return raw
        }
    }

    /// Écrit (ou réécrit) l'instantané de la liste dans le cache mémoire.
    /// Appelé après un chargement complet, et à chaque mutation de `items`
    /// via `didSet` tant que la liste a été chargée au moins une fois.
    private func storeListSnapshot() {
        DirectoryListStore.shared.store(
            source: source,
            driveId: driveId,
            orderBy: orderBy,
            order: order,
            items: items,
            cursor: cursor,
            hasMore: hasMore,
            totalItemCount: totalItemCount
        )
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
        resortAfterMerge()
    }

    /// Re-trie la grille selon le tri serveur courant (`orderBy` / `order`)
    /// après une insertion : l'ancien code triait toujours par nom, ce qui
    /// écrasait un tri actif par date, type ou taille. Dossiers en premier,
    /// comme partout ailleurs. Sans tri serveur (ordre d'origine), le tri
    /// alphabétique par défaut est conservé.
    private func resortAfterMerge() {
        let ascending = order != "desc"
        func dateOrder(_ lhs: Double?, _ rhs: Double?) -> Bool {
            switch (lhs, rhs) {
            case let (l?, r?): return ascending ? l < r : l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
        switch orderBy.first {
        case "last_modified_at":
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return dateOrder($0.lastModifiedAt, $1.lastModifiedAt)
            }
        case "added_at":
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return dateOrder($0.addedAt, $1.addedAt)
            }
        case "size":
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                let l = $0.size ?? -1
                let r = $1.size ?? -1
                if l == r { return $0.id < $1.id }
                return ascending ? l < r : l > r
            }
        case "type":
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                let l = $0.fileKind.rawValue
                let r = $1.fileKind.rawValue
                if l == r {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return ascending ? l < r : l > r
            }
        default:
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
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
            mutationErrorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
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
            mutationErrorMessage = "Suppression impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Actions de masse

    /// Applique une opération API à chaque identifiant avec une concurrence
    /// bornée : les versions séquentielles faisaient attendre un aller-retour
    /// réseau complet par élément (une sélection de 50 fichiers pouvait
    /// prendre plusieurs dizaines de secondes). Renvoie les identifiants
    /// réussis et la première erreur rencontrée.
    private func performConcurrently(
        ids: Set<Int>,
        operation: @escaping @Sendable (Int) async throws -> Void
    ) async -> (succeeded: Set<Int>, firstError: Error?) {
        let orderedIDs = Array(ids)
        let concurrency = 4
        var succeeded: Set<Int> = []
        var firstError: Error?
        var index = 0

        while index < orderedIDs.count {
            let chunk = Array(orderedIDs[index..<min(index + concurrency, orderedIDs.count)])
            index += chunk.count
            await withTaskGroup(of: (Int, Error?).self) { group in
                for id in chunk {
                    group.addTask {
                        do {
                            try await operation(id)
                            return (id, nil)
                        } catch {
                            return (id, error)
                        }
                    }
                }
                for await (id, error) in group {
                    if let error {
                        if firstError == nil { firstError = error }
                    } else {
                        succeeded.insert(id)
                    }
                }
            }
        }

        return (succeeded, firstError)
    }

    /// Message d'échec partiel identique à l'ancien comportement séquentiel.
    private func reportPartialFailure(
        total: Int,
        succeeded: Int,
        firstError: Error?,
        singular: String,
        plural: String
    ) {
        guard let firstError else { return }
        let failedCount = total - succeeded
        let detail = (firstError as? APIError)?.errorDescription ?? firstError.localizedDescription
        mutationErrorMessage = failedCount == 1
            ? String(format: singular, detail)
            : String(format: plural, failedCount, detail)
    }

    /// Corbeille une sélection entière ; les échecs partiels sont signalés
    /// dans `mutationErrorMessage` sans bloquer les autres suppressions.
    @discardableResult
    func trash(ids: Set<Int>) async -> Set<Int> {
        mutationErrorMessage = nil
        let service = self.service
        let driveId = self.driveId
        let (trashedIDs, firstError) = await performConcurrently(ids: ids) { id in
            try await service.trash(driveId: driveId, fileId: id)
        }
        items.removeAll { trashedIDs.contains($0.id) }
        reportPartialFailure(
            total: ids.count,
            succeeded: trashedIDs.count,
            firstError: firstError,
            singular: "Un élément n’a pas pu être supprimé : %@",
            plural: "%d éléments n’ont pas pu être supprimés : %@"
        )
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
            mutationErrorMessage = "Renommage impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
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
            mutationErrorMessage = "Couleur impossible à modifier : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Déplace tous les éléments demandés. Les réussites disparaissent
    /// immédiatement de la grille ; les éventuels échecs restent affichés.
    @discardableResult
    func move(ids: Set<Int>, to destinationDirectoryId: Int) async -> Set<Int> {
        mutationErrorMessage = nil
        let service = self.service
        let driveId = self.driveId
        let destination = destinationDirectoryId
        let (movedIDs, firstError) = await performConcurrently(ids: ids) { id in
            try await service.move(driveId: driveId, fileId: id, destinationDirectoryId: destination)
        }
        items.removeAll { movedIDs.contains($0.id) }
        reportPartialFailure(
            total: ids.count,
            succeeded: movedIDs.count,
            firstError: firstError,
            singular: "Un élément n’a pas pu être déplacé : %@",
            plural: "%d éléments n’ont pas pu être déplacés : %@"
        )
        return movedIDs
    }

    // MARK: - Corbeille

    /// Supprime définitivement un fichier de la corbeille.
    func permanentlyDelete(_ file: DriveFile) async {
        do {
            try await service.permanentlyDelete(driveId: driveId, fileId: file.id)
            items.removeAll { $0.id == file.id }
        } catch {
            mutationErrorMessage = "Suppression définitive impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Supprime définitivement une sélection entière ; les échecs partiels
    /// sont signalés dans `mutationErrorMessage` sans bloquer les autres
    /// suppressions. Renvoie les identifiants réellement supprimés.
    @discardableResult
    func permanentlyDelete(ids: Set<Int>) async -> Set<Int> {
        mutationErrorMessage = nil
        let service = self.service
        let driveId = self.driveId
        let (deletedIds, firstError) = await performConcurrently(ids: ids) { id in
            try await service.permanentlyDelete(driveId: driveId, fileId: id)
        }
        items.removeAll { deletedIds.contains($0.id) }
        reportPartialFailure(
            total: ids.count,
            succeeded: deletedIds.count,
            firstError: firstError,
            singular: "Un élément n’a pas pu être supprimé définitivement : %@",
            plural: "%d éléments n’ont pas pu être supprimés définitivement : %@"
        )
        return deletedIds
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
                mutationErrorMessage = "Restauration impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
                return false
            }
            do {
                try await service.restore(driveId: driveId, fileId: file.id, destinationDirectoryId: 1)
                items.removeAll { $0.id == file.id }
                return true
            } catch {
                mutationErrorMessage = "Restauration impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
                return false
            }
        }
    }

    /// Restaure une sélection entière de la corbeille ; les échecs partiels
    /// sont signalés dans `mutationErrorMessage` sans bloquer les autres
    /// restaurations.
    @discardableResult
    func restore(ids: Set<Int>) async -> Set<Int> {
        mutationErrorMessage = nil
        let service = self.service
        let driveId = self.driveId
        // Les destinations d'origine sont figées avant le lancement des
        // requêtes : la closure des tâches enfants n'accède pas à `items`.
        let destinations = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, items.first(where: { $0.id == id })?.parentId ?? 1)
        })
        let (restoredIDs, firstError) = await performConcurrently(ids: ids) { id in
            let destination = destinations[id] ?? 1
            do {
                try await service.restore(driveId: driveId, fileId: id, destinationDirectoryId: destination)
            } catch {
                guard destination != 1 else { throw error }
                try await service.restore(driveId: driveId, fileId: id, destinationDirectoryId: 1)
            }
        }
        items.removeAll { restoredIDs.contains($0.id) }
        reportPartialFailure(
            total: ids.count,
            succeeded: restoredIDs.count,
            firstError: firstError,
            singular: "Un élément n’a pas pu être restauré : %@",
            plural: "%d éléments n’ont pas pu être restaurés : %@"
        )
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
