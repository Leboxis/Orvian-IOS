import Foundation

/// Cache session des URLs temporaires kDrive (pour AVPlayer et les images
/// haute résolution). Les URL sont publiques et signées : aucun en-tête
/// d'authentification n'est nécessaire côté AVFoundation.
actor MediaURLCache {
    static let shared = MediaURLCache()

    private struct Key: Hashable, Sendable {
        let driveId: Int
        let fileId: Int
        let credentialFingerprint: Int
    }

    private var entries: [Key: (url: URL, expiresAt: Date)] = [:]
    private var inFlight: [Key: Task<URL?, Never>] = [:]
    private var pendingPrefetchKeys: [Key] = []
    private var prefetchWorker: Task<Void, Never>?
    private let maxConcurrentPrefetch = 2
    private let service: KDriveService

    init(service: KDriveService = KDriveService()) {
        self.service = service
    }

    func url(driveId: Int, fileId: Int) async -> URL? {
        let key = makeKey(driveId: driveId, fileId: fileId)
        if let entry = entries[key], entry.expiresAt > Date().addingTimeInterval(30) {
            return entry.url
        }
        entries[key] = nil
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task<URL?, Never> { [self] in
            defer { inFlight[key] = nil }
            guard !Task.isCancelled else { return nil }
            do {
                let url = try await service.temporaryURL(driveId: driveId, fileId: fileId)
                entries[key] = (url, Date().addingTimeInterval(3300))
                return url
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        return await task.value
    }

    /// Demande une nouvelle URL signée sans réutiliser celle conservée en
    /// mémoire. Utilisé par le lecteur lorsqu'AVFoundation refuse une URL
    /// devenue invalide entre le préchargement et la lecture.
    func freshURL(driveId: Int, fileId: Int) async -> URL? {
        let key = makeKey(driveId: driveId, fileId: fileId)
        entries[key] = nil
        return await url(driveId: driveId, fileId: fileId)
    }

    /// Invalide l'URL signée mémorisée après un échec de lecture ou une
    /// expiration anticipée du lien côté stockage.
    func invalidate(driveId: Int, fileId: Int) {
        let key = makeKey(driveId: driveId, fileId: fileId)
        entries[key] = nil
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    /// Pré-résolution régulée pour que le tap sur une vidéo démarre plus vite.
    /// La dernière position visible remplace les anciennes demandes en attente,
    /// avec deux appels réseau simultanés au maximum.
    func prefetch(driveId: Int, fileIds: [Int]) {
        let minimumExpiry = Date().addingTimeInterval(30)
        pendingPrefetchKeys = fileIds
            .map { makeKey(driveId: driveId, fileId: $0) }
            .filter {
                inFlight[$0] == nil
                    && (entries[$0]?.expiresAt ?? .distantPast) <= minimumExpiry
            }
        schedulePrefetchWorker()
    }

    /// Annule les résolutions préparatoires qui n'ont pas encore démarré.
    /// Les URL déjà obtenues restent disponibles dans le cache de session.
    func cancelPrefetch() {
        pendingPrefetchKeys.removeAll()
        prefetchWorker?.cancel()
        prefetchWorker = nil
    }

    private func schedulePrefetchWorker() {
        guard prefetchWorker == nil, !pendingPrefetchKeys.isEmpty else { return }
        prefetchWorker = Task { [weak self] in
            while let batch = await self?.popNextPrefetchBatch() {
                guard !Task.isCancelled else { break }
                await withTaskGroup(of: Void.self) { group in
                    for key in batch {
                        group.addTask { [weak self] in
                            _ = await self?.url(driveId: key.driveId, fileId: key.fileId)
                        }
                    }
                }
            }
            await self?.finishPrefetchWorker()
        }
    }

    private func popNextPrefetchBatch() -> [Key]? {
        guard !pendingPrefetchKeys.isEmpty else { return nil }
        let count = min(maxConcurrentPrefetch, pendingPrefetchKeys.count)
        let batch = Array(pendingPrefetchKeys.prefix(count))
        pendingPrefetchKeys.removeFirst(count)
        return batch
    }

    private func finishPrefetchWorker() {
        prefetchWorker = nil
        if !pendingPrefetchKeys.isEmpty {
            schedulePrefetchWorker()
        }
    }

    private func makeKey(driveId: Int, fileId: Int) -> Key {
        Key(
            driveId: driveId,
            fileId: fileId,
            credentialFingerprint: TokenStore.current()?.hashValue ?? 0
        )
    }
}
