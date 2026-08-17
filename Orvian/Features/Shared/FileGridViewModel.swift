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
    private(set) var actionErrorMessage: String?

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
            let page = try await service.page(source, driveId: driveId, cursor: nil)
            guard !Task.isCancelled else { return }
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
            actionErrorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Suppression & renommage

    func trash(_ file: DriveFile) async {
        do {
            try await service.trash(driveId: driveId, fileId: file.id)
            items.removeAll { $0.id == file.id }
        } catch {
            actionErrorMessage = "Suppression impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    func rename(_ file: DriveFile, name: String) async {
        guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
        let oldName = items[index].name
        items[index].name = name
        do {
            try await service.rename(driveId: driveId, fileId: file.id, name: name)
        } catch {
            items[index].name = oldName
            actionErrorMessage = "Renommage impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    func move(_ file: DriveFile, toDirectoryId destinationDirectoryId: Int) async {
        guard file.parentId != destinationDirectoryId else { return }
        do {
            try await service.move(
                driveId: driveId,
                fileId: file.id,
                destinationDirectoryId: destinationDirectoryId
            )
            // La même grille peut représenter un dossier, une recherche ou un
            // tag ; la recharger évite tout état local ambigu après le move.
            await reload()
        } catch {
            actionErrorMessage = "Déplacement impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Corbeille

    /// Supprime définitivement un fichier de la corbeille.
    func permanentlyDelete(_ file: DriveFile) async {
        do {
            try await service.permanentlyDelete(driveId: driveId, fileId: file.id)
            items.removeAll { $0.id == file.id }
        } catch {
            actionErrorMessage = "Suppression définitive impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
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
            actionErrorMessage = "Suppression définitive impossible : \((firstError as? APIError)?.errorDescription ?? firstError.localizedDescription)"
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
                actionErrorMessage = "Restauration impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
                return false
            }
            do {
                try await service.restore(driveId: driveId, fileId: file.id, destinationDirectoryId: 1)
                items.removeAll { $0.id == file.id }
                return true
            } catch {
                actionErrorMessage = "Restauration impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
                return false
            }
        }
    }

    func dismissActionError() {
        actionErrorMessage = nil
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
