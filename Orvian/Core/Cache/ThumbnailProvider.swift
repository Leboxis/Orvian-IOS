import UIKit

/// Pipeline de miniatures : mémoire → disque → réseau avec concurrence bornée.
///
/// - dédoublonne les requêtes en vol (une seule par fichier/taille) ;
/// - régule la concurrence réseau (max 5 téléchargements simultanés sans bloquer de thread) ;
/// - priorise les cellules visibles sur le préchargement ;
/// - purge les requêtes de préchargement obsolètes lors d'un défilement rapide ;
/// - ne mémorise jamais une absence : un 404 ou une réponse vide peut
///   simplement signifier qu'un média importé est encore en préparation ;
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
    /// Les posters de vidéos sont produits de façon asynchrone côté kDrive.
    /// Fenêtre de réessais plafonnée à ~60 s : couvre la majorité des
    /// encodages sans laisser une activité réseau/batterie persister
    /// plusieurs minutes après l'upload.
    private let uploadedMediaRetryDelays: [Duration] = [
        .zero, .seconds(2), .seconds(3), .seconds(5),
        .seconds(8), .seconds(12), .seconds(15), .seconds(15),
    ]

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

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [self] in
            defer { inFlight[key] = nil }
            // La lecture disque et le décodage s'exécutent hors de l'actor :
            // sur l'executor sérialisé, chaque décodage JPEG bloquait tous
            // les autres chargements (scroll rapide, préchargement…).
            if let image = await loadFromDisk(key) {
                return image
            }
            return await fetch(key: key, isTrashed: isTrashed)
        }
        inFlight[key] = task
        let image = await task.value
        if !Task.isCancelled, let image {
            Self.memory.setObject(image, forKey: key.nsString, cost: image.estimatedByteSize)
        }
        return image
    }

    /// Lecture disque + décodage hors de l'executor de l'actor (`nonisolated`
    /// async = global concurrent executor) : les chargements tournent en
    /// parallèle au lieu de se sérialiser derrière chaque décodage.
    private nonisolated func loadFromDisk(_ key: Key) async -> UIImage? {
        guard disk.hasEntry(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels) else {
            return nil
        }
        if let image = disk.loadImage(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels) {
            return image
        }
        // Une ancienne réponse non image ne doit pas empêcher une
        // nouvelle tentative réseau (cas des posters encore générés).
        disk.removeEntry(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
        return nil
    }

    /// Attend la disponibilité d'une miniature récemment créée. Le travail est
    /// annulable et chaque tentative passe par le cache/dédoublonnage normal.
    func thumbnailWhenAvailable(
        driveId: Int,
        fileId: Int,
        pixels: Int = DS.thumbnailPixels,
        isTrashed: Bool = false,
        includeImmediateAttempt: Bool = true
    ) async -> UIImage? {
        let delays = includeImmediateAttempt
            ? uploadedMediaRetryDelays
            : Array(uploadedMediaRetryDelays.dropFirst())
        for delay in delays {
            guard !Task.isCancelled else { return nil }
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return nil
                }
            }
            if let image = await thumbnail(
                driveId: driveId,
                fileId: fileId,
                pixels: pixels,
                isTrashed: isTrashed
            ) {
                return image
            }
        }
        return nil
    }

    /// Amorce la génération des miniatures dès la confirmation de l'upload,
    /// y compris si l'utilisateur quitte le dossier avant son affichage.
    func primeUploadedThumbnail(driveId: Int, fileId: Int) async {
        _ = await thumbnailWhenAvailable(driveId: driveId, fileId: fileId)
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

    /// Annule les téléchargements anticipés en attente. Les miniatures déjà
    /// présentes dans les caches mémoire ou disque ne sont pas supprimées.
    func cancelPrefetch() {
        pendingPrefetchKeys.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
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
                return nil
            }
            // Vérifier le contenu avant de le placer dans le cache. Une page
            // d'erreur renvoyée à tort en 2xx ne doit jamais devenir une
            // absence de miniature persistante.
            guard let image = UIImage.decode(data) else {
                return nil
            }
            // Les données validées sont conservées sans ré-encodage CPU.
            disk.store(data: data, driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
            return image
        } catch is CancellationError {
            return nil
        } catch {
            // Erreur réseau/HTTP ponctuelle : aucun marqueur. Juste après un
            // upload, kDrive peut répondre 404 quelques secondes avant que la
            // miniature soit générée ; une carte visible pourra donc réessayer.
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

    func enforceDiskLimit() {
        disk.enforceSizeLimit()
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
