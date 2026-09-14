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
    private var fetchedAt = Date.distantPast
    private let credentialFingerprint = TokenStore.credentialFingerprint()
    private(set) var isReloading = false
    /// Invalide toute réponse appartenant à un rechargement ou une pagination
    /// antérieur. Un ancien tri ne peut ainsi jamais remplacer le plus récent.
    private var dataGeneration = 0
    /// Tri serveur en cours (`order_by[]` + sens) : conservé pour que la
    /// pagination continue dans le même ordre que la première page.
    private var orderBy: [String] = []
    private var order = "asc"
    /// Empêche deux taps rapides de lancer des valeurs favorites opposées en
    /// parallèle pour le même fichier.
    private var favoriteMutationsInFlight: Set<Int> = []

    let source: FileSource
    let driveId: Int
    private let service: KDriveService

    /// Âge maximal d'un instantané servi sans revalidation réseau. Au-delà,
    /// la réouverture revalide en arrière-plan (ETag → 304 si inchangé).
    /// Pull-to-refresh, changement de tri et mutations passent toujours par
    /// le réseau, indépendamment de ce seuil.
    private static let freshSnapshotInterval: TimeInterval = 60

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
    /// Un instantané encore frais (moins de 60 s) saute cette revalidation :
    /// les endpoints coûteux côté serveur (`last_modified`, ~1 s) ne sont pas
    /// relancés à chaque bascule d'onglet.
    func loadIfNeeded() async {
        guard !isInitialLoading, !isReloading else { return }
        if loadedOnce {
            // SwiftUI peut conserver le view model alors que l'abonnement au
            // PassthroughSubject de sa vue est démonté. Vérifier aussi cet état
            // vivant au remontage, sans invalider les autres sources du drive.
            let currentSnapshot = DirectoryListSnapshot(
                items: items,
                cursor: cursor,
                hasMore: hasMore,
                totalItemCount: totalItemCount,
                orderBy: orderBy,
                order: order,
                fetchedAt: fetchedAt
            )
            if FileGridMutationCenter.shared.isSnapshotStale(
                currentSnapshot,
                source: source,
                driveId: driveId
            ) {
                await reload(forceNetwork: true)
            }
            return
        }
        let restoreGeneration = dataGeneration
        let memorySnapshot = DirectoryListStore.shared.snapshot(
            source: source,
            driveId: driveId,
            orderBy: orderBy,
            order: order
        )
        // Une lecture disque n'empêche pas SwiftUI de rendre l'écran.
        // Réserver le chargement pendant l'attente évite deux restaurations.
        isInitialLoading = true
        let diskSnapshot: DirectoryListSnapshot?
        if memorySnapshot == nil {
            diskSnapshot = await DirectoryListStore.shared.diskSnapshot(
                source: source, driveId: driveId, orderBy: orderBy, order: order
            )
        } else {
            diskSnapshot = nil
        }
        guard dataGeneration == restoreGeneration else { return }
        isInitialLoading = false
        guard !Task.isCancelled,
              credentialFingerprint == TokenStore.credentialFingerprint() else { return }
        if let snapshot = memorySnapshot ?? diskSnapshot {
            // Les onglets hors Home sont démontés et manquent donc les valeurs
            // du PassthroughSubject. Ne restaurer ni servir 60 s un snapshot
            // qui ne reflète pas une mutation confirmée pendant leur absence.
            if FileGridMutationCenter.shared.isSnapshotStale(
                snapshot,
                source: source,
                driveId: driveId
            ) {
                await reload(forceNetwork: true)
                return
            }
            // L'ordre des affectations importe : `items` en dernier déclenche
            // la resynchronisation du cache avec un état déjà complet.
            orderBy = snapshot.orderBy
            order = snapshot.order
            cursor = snapshot.cursor
            hasMore = snapshot.hasMore
            totalItemCount = snapshot.totalItemCount
            fetchedAt = snapshot.fetchedAt
            loadedOnce = true
            items = snapshot.items
            // Revalidation silencieuse : les cartes restent affichées et
            // l'ETag renvoie 304 (quelques octets) si rien n'a changé.
            // Un instantané de moins de 60 s est jugé à jour : aucun appel.
            if diskSnapshot != nil || Date().timeIntervalSince(snapshot.fetchedAt) > Self.freshSnapshotInterval {
                await reload(forceNetwork: diskSnapshot != nil)
            }
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
        guard credentialFingerprint == TokenStore.credentialFingerprint() else { return }
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
            // Les tags sont observables : leurs pastilles apparaîtront à la
            // fin de cette tâche, sans retenir la publication des fichiers.
            let categoryDriveId = driveId
            let categoryCredential = credentialFingerprint
            Task {
                guard categoryCredential == TokenStore.credentialFingerprint() else { return }
                await CategoryLibrary.shared.ensureLoaded(for: categoryDriveId)
            }
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
            guard !Task.isCancelled, dataGeneration == requestGeneration,
                  credentialFingerprint == TokenStore.credentialFingerprint() else { return }
            // Curseur et compteur d'abord, items en dernier : la sauvegarde
            // déclenchée par `didSet` capture toujours un état cohérent.
            cursor = page.cursor
            hasMore = page.hasMore ?? false
            totalItemCount = freshCount
            fetchedAt = Date()
            loadedOnce = true
            items = filterItemsIfNeeded(page.data ?? [])
        } catch {
            guard !Task.isCancelled, dataGeneration == requestGeneration,
                  credentialFingerprint == TokenStore.credentialFingerprint() else { return }
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
            guard !Task.isCancelled, dataGeneration == requestGeneration,
                  credentialFingerprint == TokenStore.credentialFingerprint() else { return }
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
            guard !Task.isCancelled, dataGeneration == requestGeneration,
                  credentialFingerprint == TokenStore.credentialFingerprint() else { return }
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

    /// Recale localement le compteur du dossier après corbeille, déplacement
    /// ou import : évite un aller-retour `count` juste pour le badge.
    private func adjustItemCount(by delta: Int) {
        guard delta != 0, case .directory = source, let current = totalItemCount else { return }
        totalItemCount = max(0, current + delta)
    }

    /// Écrit (ou réécrit) l'instantané de la liste dans le cache mémoire.
    /// Appelé après un chargement complet, et à chaque mutation de `items`
    /// via `didSet` tant que la liste a été chargée au moins une fois.
    private func storeListSnapshot() {
        guard credentialFingerprint == TokenStore.credentialFingerprint() else { return }
        DirectoryListStore.shared.store(
            source: source,
            driveId: driveId,
            orderBy: orderBy,
            order: order,
            items: items,
            cursor: cursor,
            hasMore: hasMore,
            totalItemCount: totalItemCount,
            fetchedAt: fetchedAt
        )
    }

    /// Insère immédiatement les fichiers confirmés par la réponse d'upload.
    /// Cela masque le léger délai possible de l'index du dossier côté serveur,
    /// sans déclencher plusieurs rechargements réseau successifs.
    func mergeUploaded(_ uploadedFiles: [DriveFile]) {
        mergeUploaded(uploadedFiles, broadcast: true)
    }

    private func mergeUploaded(_ uploadedFiles: [DriveFile], broadcast: Bool) {
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
            if file.updatedAt == nil { file.updatedAt = now }
            return file
        }
        let uploadedIDs = Set(merged.map(\.id))
        let existingIDs = Set(items.map(\.id))
        // Compteur d'abord, items ensuite : le snapshot issu de `didSet`
        // capture le badge recalé avec les cartes insérées.
        adjustItemCount(by: merged.filter { !existingIDs.contains($0.id) }.count)
        items.removeAll { uploadedIDs.contains($0.id) }
        items.append(contentsOf: merged)
        resortAfterMerge()
        if broadcast {
            DirectoryListStore.shared.mergeRecentUploads(driveId: driveId, files: merged)
            FileGridMutationCenter.shared.publish(.uploaded(driveId: driveId, files: merged))
        }
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
        if case .recents = source, orderBy.isEmpty {
            items.sort {
                ($0.updatedAt ?? $0.lastModifiedAt ?? $0.addedAt ?? 0) >
                ($1.updatedAt ?? $1.lastModifiedAt ?? $1.addedAt ?? 0)
            }
            return
        }
        switch orderBy.first {
        case "updated_at":
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return dateOrder($0.updatedAt ?? $0.lastModifiedAt, $1.updatedAt ?? $1.lastModifiedAt)
            }
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
    /// Dans l'onglet Favoris, la carte reste présentée pendant la requête puis
    /// n'est retirée qu'après confirmation du serveur.
    @discardableResult
    func toggleFavorite(_ file: DriveFile) async -> Bool {
        guard !favoriteMutationsInFlight.contains(file.id),
              let index = items.firstIndex(where: { $0.id == file.id }) else { return false }
        favoriteMutationsInFlight.insert(file.id)
        defer { favoriteMutationsInFlight.remove(file.id) }
        mutationErrorMessage = nil
        let oldValue = items[index].isFavorite
        let newValue = !(oldValue ?? false)
        let shouldRemove = source == .favorites && !newValue
        items[index].isFavorite = newValue
        do {
            try await service.setFavorite(driveId: driveId, fileId: file.id, favorite: newValue)
            if shouldRemove {
                items.removeAll { $0.id == file.id }
            }
            FileGridMutationCenter.shared.publish(
                .favorite(driveId: driveId, fileId: file.id, isFavorite: newValue)
            )
            return true
        } catch {
            if let restoredIndex = items.firstIndex(where: { $0.id == file.id }),
               items[restoredIndex].isFavorite == newValue {
                items[restoredIndex].isFavorite = oldValue
            }
            mutationErrorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
            return false
        }
    }

    // MARK: - Tags

    /// Met à jour localement les catégories (tags) d'un fichier après
    /// confirmation de l'API, pour que les pastilles des cartes suivent
    /// immédiatement (éditeur de tags et fiche détail).
    func updateCategories(for file: DriveFile, category: Category, applied: Bool) {
        applyCategoryChange(fileId: file.id, category: category, applied: applied)
        // TagsEditorSheet exécute addCategory/removeCategory et n'appelle ce
        // callback qu'après succès : aucune seconde requête n'est lancée ici.
        FileGridMutationCenter.shared.publish(
            .category(driveId: driveId, fileId: file.id, category: category, applied: applied)
        )
    }

    /// Applique une mutation deja confirmee par une autre interface, telle que
    /// la visionneuse ou le dossier resté ouvert derrière la recherche, sans
    /// repeter l'appel API.
    @discardableResult
    func apply(_ mutation: FileGridMutation) -> Bool {
        guard mutation.driveId == driveId else { return false }
        switch mutation {
        case let .favorite(_, fileId, isFavorite):
            return applyFavoriteChange(fileId: fileId, isFavorite: isFavorite)
        case let .category(_, fileId, category, applied):
            return applyCategoryChange(fileId: fileId, category: category, applied: applied)
        case let .rename(_, fileId, name):
            if let index = items.firstIndex(where: { $0.id == fileId }) {
                items[index].name = name
            }
            // Un renommage peut ajouter ou retirer un résultat de recherche ;
            // seul le serveur peut recalculer cette appartenance.
            if case .search = source { return true }
            return false
        case let .color(_, fileId, color):
            if let index = items.firstIndex(where: { $0.id == fileId }) {
                items[index].color = color
            }
            return false
        case let .removal(_, fileIds):
            items.removeAll { fileIds.contains($0.id) }
            return false
        case .moved:
            var updated = items
            let needsReload = mutation.applyMove(to: &updated, source: source)
            adjustItemCount(by: updated.count - items.count)
            if updated != items { items = updated }
            return needsReload
        case let .trashed(_, fileIds):
            if case .trash = source {
                let existingIds = Set(items.map(\.id))
                return !fileIds.isSubset(of: existingIds)
            }
            items.removeAll { fileIds.contains($0.id) }
            return false
        case let .uploaded(_, files):
            if case .recents = source {
                mergeUploaded(files, broadcast: false)
            }
            return false
        }
    }

    /// Renvoie vrai uniquement si la source Favoris doit récupérer un nouvel
    /// élément absent de sa page actuelle.
    private func applyFavoriteChange(fileId: Int, isFavorite: Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == fileId }) else {
            return source == .favorites && isFavorite
        }
        if source == .favorites && !isFavorite {
            items.remove(at: index)
        } else {
            items[index].isFavorite = isFavorite
        }
        return false
    }

    /// Renvoie vrai si une source de tag doit récupérer un fichier qui vient
    /// d'entrer dans la catégorie mais n'est pas présent dans sa page locale.
    private func applyCategoryChange(fileId: Int, category: Category, applied: Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == fileId }) else {
            if case let .category(categoryId) = source {
                return categoryId == category.id && applied
            }
            return false
        }
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
        return false
    }

    // MARK: - Suppression, renommage & déplacement

    func trash(_ file: DriveFile) async {
        do {
            try await service.trash(driveId: driveId, fileId: file.id)
            adjustItemCount(by: -1)
            items.removeAll { $0.id == file.id }
            FileGridMutationCenter.shared.publish(
                .trashed(driveId: driveId, fileIds: [file.id])
            )
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
        let results = await mapBounded(orderedIDs, concurrency: 4) { id -> Result<Void, Error> in
            do {
                try await operation(id)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        var succeeded: Set<Int> = []
        var firstError: Error?
        for (index, result) in results.enumerated() {
            switch result {
            case .success:
                succeeded.insert(orderedIDs[index])
            case let .failure(error):
                if firstError == nil { firstError = error }
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
        adjustItemCount(by: -trashedIDs.count)
        items.removeAll { trashedIDs.contains($0.id) }
        // Les grilles ouvertes du même drive (ex. recherche au-dessus du
        // dossier) retirent les cartes confirmées sans rechargement réseau.
        if !trashedIDs.isEmpty {
            FileGridMutationCenter.shared.publish(.trashed(driveId: driveId, fileIds: trashedIDs))
        }
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
            FileGridMutationCenter.shared.publish(
                .rename(driveId: driveId, fileId: file.id, name: name)
            )
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
            FileGridMutationCenter.shared.publish(
                .color(driveId: driveId, fileId: file.id, color: color)
            )
        } catch {
            if let restoredIndex = items.firstIndex(where: { $0.id == file.id }),
               items[restoredIndex].color == color {
                items[restoredIndex].color = oldColor
            }
            mutationErrorMessage = "Couleur impossible à modifier : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Déplace tous les éléments demandés. Seul le dossier quitté retire
    /// les réussites ; les listes de favoris et de tags les conservent.
    @discardableResult
    func move(ids: Set<Int>, to destinationDirectoryId: Int) async -> Set<Int> {
        mutationErrorMessage = nil
        let service = self.service
        let driveId = self.driveId
        let destination = destinationDirectoryId
        let (movedIDs, firstError) = await performConcurrently(ids: ids) { id in
            try await service.move(driveId: driveId, fileId: id, destinationDirectoryId: destination)
        }
        if !movedIDs.isEmpty {
            let mutation = FileGridMutation.moved(
                driveId: driveId, fileIds: movedIDs, destinationDirectoryId: destination
            )
            let needsReload = apply(mutation)
            FileGridMutationCenter.shared.publish(mutation)
            if needsReload { await reload(forceNetwork: true) }
        }
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
            let date = Date(timeIntervalSince1970: file.updatedAt ?? file.lastModifiedAt ?? file.addedAt ?? 0)
            if let last = buckets.last, calendar.isDate(last.0, equalTo: date, toGranularity: component) {
                buckets[buckets.count - 1].1.append(file)
            } else {
                buckets.append((date, [file]))
            }
        }
        return buckets.map { Group(title: title($0.0), files: $0.1) }
    }
}
