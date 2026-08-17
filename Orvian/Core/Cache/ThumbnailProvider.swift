import UIKit

/// Régulateur de concurrence purement asynchrone (aucun thread bloqué).
private final class AsyncThrottler: @unchecked Sendable {
    private let maxConcurrent: Int
    private var activeCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        let shouldWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if activeCount < maxConcurrent {
                activeCount += 1
                return false
            }
            return true
        }()

        if shouldWait {
            await withCheckedContinuation { continuation in
                lock.lock()
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    private func release() {
        lock.lock()
        if !continuations.isEmpty {
            let next = continuations.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            activeCount = max(0, activeCount - 1)
            lock.unlock()
        }
    }
}

/// Pipeline de miniatures : mémoire → disque → réseau avec concurrence bornée.
///
/// - dédoublonne les requêtes en vol (une seule par fichier/taille) ;
/// - régule la concurrence réseau (max 5 téléchargements simultanés sans bloquer de thread) ;
/// - priorise les cellules visibles sur le préchargement ;
/// - purge les requêtes de préchargement obsolètes lors d'un défilement rapide ;
/// - mémorise les « pas de miniature » pour ne pas re-demander ;
/// - le décodage et la préparation s'exécutent hors du MainActor.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private let disk: DiskImageCache
    private let service: KDriveService
    private let throttler = AsyncThrottler(maxConcurrent: 5)
    private var inFlight: [Key: Task<UIImage?, Never>] = [:]

    private var pendingPrefetchKeys: [Key] = []
    private var pendingPrefetchIsTrashed = false
    private var prefetchTask: Task<Void, Never>?
    private let maxPendingPrefetch = 6

    private struct Key: Hashable {
        let driveId: Int
        let fileId: Int
        let pixels: Int

        var nsString: NSString { "\(driveId)-\(fileId)-\(pixels)" as NSString }
    }

    init(service: KDriveService = KDriveService(), disk: DiskImageCache = .init()) {
        self.service = service
        self.disk = disk
    }

    /// Accès synchrone ultra-rapide au cache mémoire (sans saut de thread).
    nonisolated func cachedMemoryThumbnail(driveId: Int, fileId: Int, pixels: Int = DS.thumbnailPixels) -> UIImage? {
        let key = "\(driveId)-\(fileId)-\(pixels)" as NSString
        return Self.memory.object(forKey: key)
    }

    /// Miniature pour une carte visible ; nil si le fichier n'en a pas ou si annulé.
    /// `isTrashed` : les fichiers de la corbeille utilisent l'endpoint dédié.
    func thumbnail(driveId: Int, fileId: Int, pixels: Int = DS.thumbnailPixels, isTrashed: Bool = false) async -> UIImage? {
        let key = Key(driveId: driveId, fileId: fileId, pixels: pixels)

        if let cached = Self.memory.object(forKey: key.nsString) {
            return cached
        }
        if disk.hasEntry(driveId: driveId, fileId: fileId, pixels: pixels) {
            if let image = disk.loadImage(driveId: driveId, fileId: fileId, pixels: pixels) {
                Self.memory.setObject(image, forKey: key.nsString, cost: image.estimatedByteSize)
                return image
            }
            return nil // marqueur « pas de miniature » déjà sur disque
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [self] in
            defer { inFlight[key] = nil }
            return await fetch(key: key, isTrashed: isTrashed)
        }
        inFlight[key] = task
        let image = await task.value
        if !Task.isCancelled, let image {
            Self.memory.setObject(image, forKey: key.nsString, cost: image.estimatedByteSize)
        }
        return image
    }

    /// Préchargement discret avec régulation de concurrence et abandon des requêtes lointaines.
    func prefetch(driveId: Int, fileIds: [Int], pixels: Int = DS.thumbnailPixels, isTrashed: Bool = false) {
        var newestKeys: [Key] = []
        for fileId in fileIds {
            let key = Key(driveId: driveId, fileId: fileId, pixels: pixels)
            guard inFlight[key] == nil,
                  Self.memory.object(forKey: key.nsString) == nil,
                  !disk.hasEntry(driveId: driveId, fileId: fileId, pixels: pixels)
            else { continue }
            if !newestKeys.contains(key) {
                newestKeys.append(key)
            }
        }

        // La dernière position visible remplace les anciennes demandes encore
        // en attente. Le téléchargement déjà commencé peut finir, mais aucune
        // longue file de miniatures hors écran ne subsiste.
        pendingPrefetchKeys = Array(newestKeys.prefix(maxPendingPrefetch))
        pendingPrefetchIsTrashed = isTrashed

        schedulePrefetchWorker(isTrashed: isTrashed)
    }

    private func schedulePrefetchWorker(isTrashed: Bool) {
        guard prefetchTask == nil else { return }
        prefetchTask = Task { [weak self] in
            while let nextKey = await self?.popNextPrefetchKey() {
                guard !Task.isCancelled else { break }
                _ = await self?.thumbnail(driveId: nextKey.driveId, fileId: nextKey.fileId, pixels: nextKey.pixels, isTrashed: isTrashed)
            }
            await self?.clearPrefetchTask()
        }
    }

    private func popNextPrefetchKey() -> Key? {
        guard !pendingPrefetchKeys.isEmpty else { return nil }
        return pendingPrefetchKeys.removeFirst()
    }

    private func clearPrefetchTask() {
        prefetchTask = nil
        if !pendingPrefetchKeys.isEmpty {
            schedulePrefetchWorker(isTrashed: pendingPrefetchIsTrashed)
        }
    }

    private func fetch(key: Key, isTrashed: Bool) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        do {
            let data = try await throttler.withPermit {
                try Task.checkCancellation()
                return try await service.thumbnailData(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels, isTrashed: isTrashed)
            }
            guard !Task.isCancelled else { return nil }
            guard !data.isEmpty else {
                disk.storeMarker(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
                return nil
            }
            // 1. Sauvegarde directe des données brutes reçues (JPEG, PNG, WebP...) sans ré-encodage CPU
            disk.store(data: data, driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)

            // 2. Décodage et préparation d'image hors du MainActor
            guard let image = UIImage.decode(data) else {
                disk.storeMarker(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
                return nil
            }
            return image
        } catch is CancellationError {
            return nil
        } catch {
            // Erreur réseau/HTTP ponctuelle : pas de marqueur, on réessaiera.
            if let apiError = error as? APIError, case let .http(status, _, _) = apiError, status == 404 {
                disk.storeMarker(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
            }
            return nil
        }
    }

    // MARK: - Maintenance

    func purgeDiskCache() {
        Self.memory.removeAllObjects()
        pendingPrefetchKeys.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
        disk.purge()
    }

    func diskCacheSize() -> Int {
        disk.totalSize()
    }
}

private extension UIImage {
    /// Décodage et décompression d'image préparée pour l'affichage (exécuté hors du MainActor).
    static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    var estimatedByteSize: Int {
        Int(size.width * size.height * 4)
    }
}
