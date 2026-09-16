import Foundation

/// Point d'entrée partagé du petit flux « Uploads récents ».
///
/// Il restaure d'abord le dernier instantané disque, puis mutualise la requête
/// réseau démarrée au clic sur l'onglet et celle de la vue Profil. Le montage
/// de la vue ne déclenche donc pas un second `last_modified`.
@MainActor
final class RecentUploadsLoader {
    static let shared = RecentUploadsLoader()

    static let source = FileSource.recents(limit: 12)
    private static let revalidationInterval: TimeInterval = 60

    private struct InFlight {
        let id: UUID
        let requiresNetwork: Bool
        /// Une lecture forcée peut satisfaire tous les appelants. L'inverse
        /// est faux : un geste manuel ne doit pas rejoindre une revalidation
        /// ordinaire susceptible d'utiliser le cache HTTP.
        let forcesNetwork: Bool
        let task: Task<DirectoryListSnapshot?, Never>
    }

    private var inFlightByDrive: [Int: InFlight] = [:]
    private var restoredFromDisk: Set<Int> = []
    private let service = KDriveService()

    private init() {}

    /// Retourne le cache mémoire ou disque sans attendre le réseau.
    func cachedSnapshot(driveId: Int) async -> DirectoryListSnapshot? {
        if let memory = DirectoryListStore.shared.snapshot(
            source: Self.source, driveId: driveId, orderBy: [], order: "asc"
        ) {
            return memory
        }
        guard let disk = await DirectoryListStore.shared.diskSnapshot(
            source: Self.source, driveId: driveId, orderBy: [], order: "asc"
        ) else { return nil }
        DirectoryListStore.shared.store(
            source: Self.source,
            driveId: driveId,
            orderBy: [],
            order: "asc",
            items: disk.items,
            cursor: disk.cursor,
            hasMore: disk.hasMore,
            totalItemCount: disk.totalItemCount,
            fetchedAt: disk.fetchedAt
        )
        restoredFromDisk.insert(driveId)
        return disk
    }

    /// Renvoie l'état réseau courant. Les appels concurrents pour un même
    /// drive attendent la même tâche afin de ne pas doubler la requête lente.
    func refresh(driveId: Int, forceNetwork: Bool = false) async -> DirectoryListSnapshot? {
        let cached = DirectoryListStore.shared.snapshot(
            source: Self.source, driveId: driveId, orderBy: [], order: "asc"
        )
        let cameFromDisk = restoredFromDisk.remove(driveId) != nil
        if !forceNetwork, !cameFromDisk, let cached,
           Date().timeIntervalSince(cached.fetchedAt) < Self.revalidationInterval {
            return cached
        }
        let forcesNetwork = forceNetwork || cameFromDisk
        if let inFlight = inFlightByDrive[driveId] {
            if !forcesNetwork || inFlight.forcesNetwork {
                return await inFlight.task.value
            }
            // La nouvelle demande exige une lecture plus fraîche. Annuler la
            // tâche ordinaire empêche surtout son résultat tardif d'écraser le
            // rafraîchissement forcé ; l'APIClient gère sa transaction réseau.
            inFlight.task.cancel()
        }

        let credential = TokenStore.credentialFingerprint()
        let requestID = UUID()
        let requestStartedAt = Date().timeIntervalSince1970
        let task = Task { [service] in
            guard !Task.isCancelled,
                  let page = try? await service.page(
                Self.source,
                driveId: driveId,
                cursor: nil,
                forceNetwork: forcesNetwork
            ),
                  !Task.isCancelled
            else { return cached }
            guard !Task.isCancelled, credential == TokenStore.credentialFingerprint() else { return nil }
            let serverFiles = (page.data ?? []).filter { !$0.isDirectory }
            // Si un upload s'est terminé pendant l'aller-retour, une réponse
            // d'index encore en retard ne doit pas faire disparaître sa carte.
            let localAdditions = DirectoryListStore.shared.snapshot(
                source: Self.source, driveId: driveId, orderBy: [], order: "asc"
            )?.items.filter {
                ($0.updatedAt ?? $0.lastModifiedAt ?? $0.addedAt ?? 0) >= requestStartedAt
            } ?? []
            let localIDs = Set(localAdditions.map(\.id))
            let files = localAdditions + serverFiles.filter { !localIDs.contains($0.id) }
            let snapshot = DirectoryListSnapshot(
                items: files,
                cursor: page.cursor,
                hasMore: page.hasMore ?? false,
                totalItemCount: nil,
                orderBy: [],
                order: "asc",
                fetchedAt: Date()
            )
            // Ne pas écraser une grille déjà paginée avec les seules 12
            // cartes de l'aperçu. Le Profil reçoit tout de même `snapshot`.
            let existingCount = DirectoryListStore.shared.snapshot(
                source: Self.source, driveId: driveId, orderBy: [], order: "asc"
            )?.items.count ?? 0
            if existingCount <= files.count {
                DirectoryListStore.shared.store(
                    source: Self.source,
                    driveId: driveId,
                    orderBy: [],
                    order: "asc",
                    items: snapshot.items,
                    cursor: snapshot.cursor,
                    hasMore: snapshot.hasMore,
                    totalItemCount: nil,
                    fetchedAt: snapshot.fetchedAt
                )
            }
            return snapshot
        }
        inFlightByDrive[driveId] = InFlight(
            id: requestID,
            forcesNetwork: forcesNetwork,
            task: task
        )
        let result = await task.value
        if inFlightByDrive[driveId]?.id == requestID {
            inFlightByDrive[driveId] = nil
        }
        return result
    }

    func prefetch(driveId: Int) async {
        _ = await cachedSnapshot(driveId: driveId)
        _ = await refresh(driveId: driveId)
    }
}
