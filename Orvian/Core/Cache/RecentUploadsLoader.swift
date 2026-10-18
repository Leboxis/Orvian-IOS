import Foundation

/// Point d'entrée partagé du petit flux « Uploads récents ».
///
/// Le clic sur Profil démarre d'abord une requête globale de 60 fichiers.
/// La vue rejoint cette requête avant de charger ses miniatures. Le cache
/// disque reste disponible pour les autres consommateurs du flux.
@MainActor
final class RecentUploadsLoader {
    static let shared = RecentUploadsLoader()

    static let pageSize = 60
    static let source = FileSource.recents(limit: pageSize)
    private static let revalidationInterval: TimeInterval = 60
    /// L'index serveur (`last_modified`) peut mettre plusieurs minutes à
    /// converger après un upload. Au-delà de l'aller-retour en cours, un
    /// ajout local récent absent de la réponse serveur est donc conservé en
    /// tête au lieu de disparaître ~1 s après l'affichage du cache.
    private static let recentUploadGraceInterval: TimeInterval = 10 * 60

    private struct InFlight {
        let id: UUID
        let credential: String
        /// Une lecture forcée peut satisfaire tous les appelants. L'inverse
        /// est faux : un geste manuel ne doit pas rejoindre une revalidation
        /// ordinaire susceptible d'utiliser le cache HTTP.
        let forcesNetwork: Bool
        let task: Task<RefreshOutcome?, Never>
    }

    private var inFlightByDrive: [Int: InFlight] = [:]
    private var profileVisit: (id: UUID, driveId: Int, credential: String, generation: Int,
                               task: Task<RefreshOutcome?, Never>)?
    private var restoredFromDisk: [Int: String] = [:]
    private var generation = 0
    private struct FirstPage {
        let credential: String
        let generation: Int
        var snapshot: DirectoryListSnapshot
    }
    // Séparé de la grille paginée : un nouvel aperçu ne mélange jamais sa
    // première page fraîche avec le curseur des anciennes pages.
    private var firstPageByDrive: [Int: FirstPage] = [:]
    private struct LocalUpload {
        let file: DriveFile
        let credential: String
        let expiresAt: Date
    }
    private var pendingLocalUploadsByDrive: [Int: [Int: LocalUpload]] = [:]

    func recordLocalUploads(driveId: Int, files: [DriveFile]) {
        guard let credential = TokenStore.credentialFingerprint() else { return }
        let files = files.filter { !$0.isDirectory }
        if var first = firstPageByDrive[driveId], first.credential == credential, first.generation == generation {
            let ids = Set(files.map(\.id))
            first.snapshot.items = files + first.snapshot.items.filter { !ids.contains($0.id) }
            firstPageByDrive[driveId] = first
        }
        let expiresAt = Date().addingTimeInterval(Self.recentUploadGraceInterval)
        for file in files where !file.isDirectory {
            pendingLocalUploadsByDrive[driveId, default: [:]][file.id] = LocalUpload(
                file: file, credential: credential, expiresAt: expiresAt
            )
        }
    }

    func removeLocalUploads(driveId: Int, fileIds: Set<Int>) {
        for id in fileIds { pendingLocalUploadsByDrive[driveId]?[id] = nil }
        if var first = firstPageByDrive[driveId],
           first.credential == TokenStore.credentialFingerprint(), first.generation == generation {
            first.snapshot.items.removeAll { fileIds.contains($0.id) }
            firstPageByDrive[driveId] = first
        }
    }

    private func pendingLocalUploads(driveId: Int, serverFiles: [DriveFile]) -> [DriveFile] {
        let serverIDs = Set(serverFiles.map(\.id))
        let credential = TokenStore.credentialFingerprint()
        let now = Date()
        let pending = (pendingLocalUploadsByDrive[driveId] ?? [:]).filter {
            $0.value.credential == credential && $0.value.expiresAt > now
                && !serverIDs.contains($0.key)
        }
        pendingLocalUploadsByDrive[driveId] = pending.isEmpty ? nil : pending
        return pending.values.sorted { $0.expiresAt > $1.expiresAt }.map(\.file)
    }
    private let service = KDriveService()

    private init() {}

    private func latestMemorySnapshot(driveId: Int) -> DirectoryListSnapshot? {
        let memory = DirectoryListStore.shared.snapshot(
            source: Self.source, driveId: driveId, orderBy: [], order: "asc"
        ).flatMap { snapshot in
            FileGridMutationCenter.shared.isSnapshotStale(snapshot, source: Self.source, driveId: driveId) ? nil : snapshot
        }
        guard let first = firstPageByDrive[driveId] else { return memory }
        guard first.credential == TokenStore.credentialFingerprint(), first.generation == generation,
              Date().timeIntervalSince(first.snapshot.fetchedAt) < Self.revalidationInterval,
              !FileGridMutationCenter.shared.isSnapshotStale(first.snapshot, source: Self.source, driveId: driveId) else {
            firstPageByDrive[driveId] = nil
            return memory
        }
        // À date égale, le magasin reflète les mutations locales les plus récentes.
        if let memory, memory.fetchedAt >= first.snapshot.fetchedAt { return memory }
        return first.snapshot
    }

    /// État mémoire validé commun au Profil et à la grille, sans accès disque.
    func cachedMemorySnapshot(driveId: Int) -> DirectoryListSnapshot? {
        guard TokenStore.credentialFingerprint() != nil else { return nil }
        return latestMemorySnapshot(driveId: driveId)
    }

    /// Retourne le cache mémoire ou disque sans attendre le réseau.
    func cachedSnapshot(driveId: Int) async -> DirectoryListSnapshot? {
        guard let credential = TokenStore.credentialFingerprint(), !Task.isCancelled else { return nil }
        let restoreGeneration = generation
        if let memory = latestMemorySnapshot(driveId: driveId) { return memory }
        let disk = await DirectoryListStore.shared.diskSnapshot(
            source: Self.source, driveId: driveId, orderBy: [], order: "asc"
        )
        guard credential == TokenStore.credentialFingerprint(),
              restoreGeneration == generation, !Task.isCancelled else { return nil }
        // Une requête réseau ou un upload a pu remplir le magasin pendant la
        // lecture disque : ne jamais remplacer cet état plus récent.
        if let memory = latestMemorySnapshot(driveId: driveId) { return memory }
        guard let disk,
              !FileGridMutationCenter.shared.isSnapshotStale(disk, source: Self.source, driveId: driveId) else { return nil }
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
        restoredFromDisk[driveId] = credential
        return disk
    }

    /// Renvoie l'état réseau courant. Les appels concurrents pour un même
    /// drive attendent la même tâche afin de ne pas doubler la requête lente.
    func refresh(driveId: Int, forceNetwork: Bool = false) async -> DirectoryListSnapshot? {
        await refreshOutcome(driveId: driveId, forceNetwork: forceNetwork)?.snapshot
    }

    struct RefreshOutcome {
        let snapshot: DirectoryListSnapshot?
        let error: Error?
    }

    /// L'erreur appartient à cette requête, jamais à un état partagé entre drives.
    func refreshOutcome(driveId: Int, forceNetwork: Bool = false) async -> RefreshOutcome? {
        guard let credential = TokenStore.credentialFingerprint(), !Task.isCancelled else { return nil }
        let refreshGeneration = generation
        let cached = latestMemorySnapshot(driveId: driveId)
        let cameFromDisk = restoredFromDisk.removeValue(forKey: driveId) == credential
        let forcesNetwork = forceNetwork || cameFromDisk
        if let inFlight = inFlightByDrive[driveId] {
            if inFlight.credential == credential, !forcesNetwork || inFlight.forcesNetwork {
                let result = await inFlight.task.value
                guard !Task.isCancelled, refreshGeneration == generation,
                      credential == TokenStore.credentialFingerprint() else { return nil }
                return result
            }
            // La nouvelle demande exige une lecture plus fraîche. Annuler la
            // tâche ordinaire empêche surtout son résultat tardif d'écraser le
            // rafraîchissement forcé ; l'APIClient gère sa transaction réseau.
            inFlight.task.cancel()
        }

        if !forceNetwork, !cameFromDisk, let cached,
           Date().timeIntervalSince(cached.fetchedAt) < Self.revalidationInterval {
            return RefreshOutcome(snapshot: cached, error: nil)
        }
        let requestID = UUID()
        let requestStartedAt = Date()
        let task = Task<RefreshOutcome?, Never> { [service] in
            guard !Task.isCancelled, credential == TokenStore.credentialFingerprint(),
                  refreshGeneration == generation else { return nil }
            do {
                let page = try await service.page(
                Self.source,
                driveId: driveId,
                cursor: nil,
                forceNetwork: forcesNetwork
                )
            guard !Task.isCancelled, credential == TokenStore.credentialFingerprint(),
                  refreshGeneration == generation else { return nil }
            let serverFiles = (page.data ?? []).filter { !$0.isDirectory }
            // Preserve only uploads confirmed in this session, never every
            // recently modified cached file absent from the server.
            let localAdditions = pendingLocalUploads(driveId: driveId, serverFiles: serverFiles)
            let localIDs = Set(localAdditions.map(\.id))
            let files = localAdditions + serverFiles.filter { !localIDs.contains($0.id) }
            let snapshot = DirectoryListSnapshot(
                items: files,
                cursor: page.cursor,
                hasMore: page.hasMore ?? false,
                totalItemCount: nil,
                orderBy: [],
                order: "asc",
                fetchedAt: requestStartedAt
            )
            // Une mutation confirmée pendant le GET prime sur sa réponse. Ne
            // marquer ni le cache ni le curseur obsolètes comme fraîchement lus.
            guard !FileGridMutationCenter.shared.isSnapshotStale(
                snapshot, source: Self.source, driveId: driveId
            ) else {
                let current = await cachedSnapshot(driveId: driveId)
                guard !Task.isCancelled, credential == TokenStore.credentialFingerprint(),
                      refreshGeneration == generation, let current else { return nil }
                return RefreshOutcome(snapshot: current, error: nil)
            }
            firstPageByDrive[driveId] = FirstPage(
                credential: credential, generation: refreshGeneration, snapshot: snapshot
            )
            // Ne pas écraser une grille déjà paginée avec les seules 60
            // cartes de l'aperçu. Le Profil reçoit tout de même `snapshot`.
            let existing = DirectoryListStore.shared.snapshot(
                source: Self.source, driveId: driveId, orderBy: [], order: "asc"
            )
            if (existing?.items.count ?? 0) <= Self.pageSize {
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
            return RefreshOutcome(snapshot: snapshot, error: nil)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      credential == TokenStore.credentialFingerprint(),
                      refreshGeneration == generation else { return nil }
                // Relire le cache courant pour conserver les uploads arrivés pendant le GET.
                let current = await cachedSnapshot(driveId: driveId)
                guard !Task.isCancelled, credential == TokenStore.credentialFingerprint(),
                      refreshGeneration == generation else { return nil }
                return RefreshOutcome(snapshot: current, error: error)
            }
        }
        inFlightByDrive[driveId] = InFlight(
            id: requestID,
            credential: credential,
            forcesNetwork: forcesNetwork,
            task: task
        )
        let result = await task.value
        if inFlightByDrive[driveId]?.id == requestID {
            inFlightByDrive[driveId] = nil
        }
        guard !Task.isCancelled, refreshGeneration == generation,
              credential == TokenStore.credentialFingerprint() else { return nil }
        return result
    }

    func clear() {
        generation &+= 1
        inFlightByDrive.values.forEach { $0.task.cancel() }
        inFlightByDrive.removeAll()
        profileVisit?.task.cancel()
        profileVisit = nil
        restoredFromDisk.removeAll()
        firstPageByDrive.removeAll()
        pendingLocalUploadsByDrive.removeAll()
    }

    /// Called synchronously at the tab tap: start the global first page before
    /// Profile mounts. No disk preview or thumbnail request precedes this GET.
    func prefetch(driveId: Int) {
        guard let credential = TokenStore.credentialFingerprint() else { return }
        let visitGeneration = generation
        let task = Task<RefreshOutcome?, Never> {
            guard credential == TokenStore.credentialFingerprint(), visitGeneration == generation else { return nil }
            return await refreshOutcome(driveId: driveId, forceNetwork: true)
        }
        profileVisit = (UUID(), driveId, credential, generation, task)
    }

    func profileVisitID(driveId: Int) -> UUID? {
        guard let visit = profileVisit, visit.driveId == driveId,
              visit.credential == TokenStore.credentialFingerprint(), visit.generation == generation else { return nil }
        return visit.id
    }

    /// Mounting, activation and the preview all await the exact tab request,
    /// even if it has already finished. Only an explicit retry starts another.
    func profileRefreshOutcome(driveId: Int, forceNetwork: Bool = false) async -> RefreshOutcome? {
        if forceNetwork || profileVisitID(driveId: driveId) == nil { prefetch(driveId: driveId) }
        guard let visit = profileVisit else { return nil }
        let result = await visit.task.value
        guard !Task.isCancelled, profileVisitID(driveId: driveId) == visit.id else { return nil }
        return result
    }
}
