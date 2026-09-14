import Combine
import Foundation

/// Diffuse les mutations deja confirmees par l'API aux grilles encore visibles.
enum FileGridMutation {
    case favorite(driveId: Int, fileId: Int, isFavorite: Bool)
    case category(driveId: Int, fileId: Int, category: Category, applied: Bool)
    case rename(driveId: Int, fileId: Int, name: String)
    case color(driveId: Int, fileId: Int, color: String)
    /// Retrait explicite (suppression), indépendant d'un déplacement.
    case removal(driveId: Int, fileIds: Set<Int>)
    case moved(driveId: Int, fileIds: Set<Int>, destinationDirectoryId: Int)
    /// Éléments dont la mise à la corbeille est confirmée. Contrairement à un
    /// déplacement, cette mutation invalide aussi une corbeille mise en cache.
    case trashed(driveId: Int, fileIds: Set<Int>)
    /// Fichiers dont l'upload vient d'être confirmé : les vues « récents »
    /// peuvent les afficher avant que l'index serveur ait convergé.
    case uploaded(driveId: Int, files: [DriveFile])

    var driveId: Int {
        switch self {
        case let .favorite(driveId, _, _), let .category(driveId, _, _, _),
             let .rename(driveId, _, _), let .color(driveId, _, _),
             let .removal(driveId, _), let .trashed(driveId, _),
             let .moved(driveId, _, _),
             let .uploaded(driveId, _):
            return driveId
        }
    }

    /// Renvoie vrai quand le serveur doit recalculer l'appartenance à la liste.
    /// La même règle sert aux grilles vivantes et à la validation des caches.
    @discardableResult
    func applyMove(to items: inout [DriveFile], source: FileSource) -> Bool {
        guard case let .moved(_, fileIds, destination) = self else { return false }
        if case .trash = source { return false }
        if case let .directory(directoryId) = source, directoryId != destination {
            items.removeAll { fileIds.contains($0.id) }
            return false
        }
        for index in items.indices where fileIds.contains(items[index].id) {
            if items[index].parentId != destination {
                items[index].parentId = destination
                items[index].path = nil // L'ancien chemin n'est plus utilisable.
            }
        }
        switch source {
        case .directory:
            return !fileIds.isSubset(of: Set(items.map(\.id)))
        case let .search(_, directoryId):
            // La recherche d'un dossier inclut ses descendants : le serveur
            // doit décider si le nouveau parent est encore dans ce périmètre.
            return directoryId != nil
        default:
            return false // Favoris, tags, récents et recherche globale restent présents.
        }
    }
}

final class FileGridMutationCenter {
    static let shared = FileGridMutationCenter()

    let mutations = PassthroughSubject<FileGridMutation, Never>()

    /// `mutations` reste un PassthroughSubject pour les vues montées. Ce petit
    /// journal couvre en plus la durée de vie du cache mémoire : une source
    /// démontée peut refuser uniquement son snapshot réellement obsolète.
    private struct RecordedMutation {
        let mutation: FileGridMutation
        let recordedAt: Date
        let credentialFingerprint: String
    }

    private var recordedMutations: [RecordedMutation] = []
    private let retentionInterval: TimeInterval = 5 * 60
    private let recordCapacity = 512

    private init() {}

    func publish(_ mutation: FileGridMutation) {
        let now = Date()
        pruneRecords(at: now)
        if let credentialFingerprint = TokenStore.credentialFingerprint() {
            recordedMutations.append(
                RecordedMutation(
                    mutation: mutation,
                    recordedAt: now,
                    credentialFingerprint: credentialFingerprint
                )
            )
            if recordedMutations.count > recordCapacity {
                recordedMutations.removeFirst(recordedMutations.count - recordCapacity)
            }
        }
        mutations.send(mutation)
    }

    /// Indique si un snapshot antérieur à une mutation confirmée ne reflète
    /// pas encore celle-ci. Le test porte sur la source et le fichier touché,
    /// afin de ne pas invalider toutes les listes du drive.
    func isSnapshotStale(
        _ snapshot: DirectoryListSnapshot,
        source: FileSource,
        driveId: Int
    ) -> Bool {
        let now = Date()
        pruneRecords(at: now)
        guard let credentialFingerprint = TokenStore.credentialFingerprint() else { return false }
        return recordedMutations.contains { record in
            record.credentialFingerprint == credentialFingerprint
                && record.mutation.driveId == driveId
                && record.recordedAt > snapshot.fetchedAt
                && !isReflected(record.mutation, in: snapshot.items, source: source)
        }
    }

    private func pruneRecords(at date: Date) {
        recordedMutations.removeAll {
            date.timeIntervalSince($0.recordedAt) >= retentionInterval
        }
    }

    private func isReflected(
        _ mutation: FileGridMutation,
        in items: [DriveFile],
        source: FileSource
    ) -> Bool {
        switch mutation {
        case let .favorite(_, fileId, isFavorite):
            let file = items.first { $0.id == fileId }
            if case .favorites = source {
                return isFavorite ? file?.isFavorite == true : file == nil
            }
            guard let file else { return true }
            return file.isFavorite == isFavorite

        case let .category(_, fileId, category, applied):
            let file = items.first { $0.id == fileId }
            if case let .category(sourceCategoryId) = source,
               sourceCategoryId == category.id {
                return applied ? file != nil : file == nil
            }
            guard let file, let categories = file.categories else { return file == nil }
            return categories.contains(where: { $0.categoryId == category.id }) == applied

        case let .rename(_, fileId, name):
            guard let file = items.first(where: { $0.id == fileId }) else { return true }
            return file.name == name

        case let .color(_, fileId, color):
            guard let file = items.first(where: { $0.id == fileId }) else { return true }
            return file.color == color

        case let .removal(_, fileIds):
            return items.allSatisfy { !fileIds.contains($0.id) }

        case .moved:
            var updated = items
            let needsReload = mutation.applyMove(to: &updated, source: source)
            return !needsReload && updated == items

        case let .trashed(_, fileIds):
            if case .trash = source {
                let existingIds = Set(items.map(\.id))
                return fileIds.isSubset(of: existingIds)
            }
            return items.allSatisfy { !fileIds.contains($0.id) }

        case .uploaded:
            // Le flux d'upload met déjà à jour son cache dédié avant de publier.
            return true
        }
    }
}
