import UIKit

/// Pipeline de miniatures : mémoire → disque → réseau avec concurrence bornée.
///
/// - dédoublonne les requêtes en vol (une seule par compte, état et fichier) ;
/// - régule la concurrence réseau (max 8 téléchargements simultanés sans bloquer de thread) ;
/// - priorise les cellules visibles sur le préchargement ;
/// - purge les requêtes de préchargement obsolètes lors d'un défilement rapide ;
/// - ne mémorise pas une absence immédiate (un 404 ou une réponse vide peut
///   simplement signifier qu'un média importé est encore en préparation),
///   mais une fenêtre complète de réessais infructueuse arme un cache
///   négatif borné dans le temps : les réapparitions de la carte cessent
///   de relancer la boucle pendant la TTL au lieu de retester 8 fois ;
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
    private let throttler = AsyncThrottler(maxConcurrent: 8)
    private var inFlight: [Key: Task<UIImage?, Never>] = [:]

    private var pendingPrefetchKeys: [Key] = []
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

    /// Cache négatif borné : une fenêtre complète de réessais terminée sans
    /// miniature y inscrit la clé. Pendant la TTL, `thumbnailWhenAvailable`
    /// renvoie nil sans relancer la boucle — sinon chaque réapparition de la
    /// carte rejouait 7 tentatives sur ~60 s pour des fichiers qui n'auront
    /// jamais de miniature (documents, archives…). La TTL laisse toutefois
    /// une nouvelle chance aux posters de vidéos longues à encoder.
    private var recentFailures: [Key: Date] = [:]
    private let failureRetryTTL: TimeInterval = 5 * 60
    private let failureCacheLimit = 512

    private struct Key: Hashable, Sendable {
        let credentialFingerprint: String
        let driveId: Int
        let fileId: Int
        let isTrashed: Bool

        var nsString: NSString {
            "\(credentialFingerprint)|\(driveId)|\(isTrashed ? "trash" : "normal")|\(fileId)" as NSString
        }
    }

    private static func currentCredentialFingerprint() -> String {
        TokenStore.credentialFingerprint() ?? "signed-out"
    }

    private static func key(driveId: Int, fileId: Int, isTrashed: Bool) -> Key {
        Key(
            credentialFingerprint: currentCredentialFingerprint(),
            driveId: driveId,
            fileId: fileId,
            isTrashed: isTrashed
        )
    }

    private static func isCurrentCredential(_ key: Key) -> Bool {
        key.credentialFingerprint == currentCredentialFingerprint()
    }

    init(service: KDriveService = KDriveService(), disk: DiskImageCache = .init()) {
        self.service = service
        self.disk = disk
    }

    /// Accès synchrone ultra-rapide au cache mémoire (sans saut de thread).
    nonisolated func cachedMemoryThumbnail(driveId: Int, fileId: Int, isTrashed: Bool) -> UIImage? {
        let key = Self.key(driveId: driveId, fileId: fileId, isTrashed: isTrashed).nsString
        return Self.memory.object(forKey: key)
    }

    /// Miniature pour une carte visible ; nil si le fichier n'en a pas ou si annulé.
    /// `isTrashed` : les fichiers de la corbeille utilisent l'endpoint dédié.
    func thumbnail(driveId: Int, fileId: Int, isTrashed: Bool = false) async -> UIImage? {
        let key = Self.key(driveId: driveId, fileId: fileId, isTrashed: isTrashed)
        return await thumbnail(for: key)
    }

    /// La clé est capturée une seule fois par demande afin que les attentes,
    /// retries et prefetch ne basculent jamais silencieusement de session.
    private func thumbnail(for key: Key) async -> UIImage? {
        guard Self.isCurrentCredential(key) else { return nil }

        if let cached = Self.memory.object(forKey: key.nsString) {
            return cached
        }

        if let existing = inFlight[key] {
            let image = await existing.value
            guard Self.isCurrentCredential(key) else { return nil }
            return image
        }

        let task = Task<UIImage?, Never> { [self] in
            defer { inFlight[key] = nil }
            // La lecture disque et le décodage s'exécutent hors de l'actor :
            // sur l'executor sérialisé, chaque décodage JPEG bloquait tous
            // les autres chargements (scroll rapide, préchargement…).
            if let image = await loadFromDisk(key) {
                return image
            }
            return await fetch(key: key)
        }
        inFlight[key] = task
        let image = await task.value
        guard !Task.isCancelled, Self.isCurrentCredential(key), let image else { return nil }
        Self.memory.setObject(image, forKey: key.nsString, cost: image.estimatedByteSize)
        // Une miniature obtenue par le chemin direct invalide une absence
        // enregistrée (poster généré entre-temps).
        recentFailures[key] = nil
        return image
    }

    /// Lecture disque + décodage hors de l'executor de l'actor (`nonisolated`
    /// async = global concurrent executor) : les chargements tournent en
    /// parallèle au lieu de se sérialiser derrière chaque décodage.
    private nonisolated func loadFromDisk(_ key: Key) async -> UIImage? {
        guard disk.hasEntry(
            credentialFingerprint: key.credentialFingerprint,
            driveId: key.driveId,
            fileId: key.fileId,
            isTrashed: key.isTrashed
        ) else {
            return nil
        }
        if let image = disk.loadImage(
            credentialFingerprint: key.credentialFingerprint,
            driveId: key.driveId,
            fileId: key.fileId,
            isTrashed: key.isTrashed
        ) {
            return image
        }
        // Une ancienne réponse non image ne doit pas empêcher une
        // nouvelle tentative réseau (cas des posters encore générés).
        disk.removeEntry(
            credentialFingerprint: key.credentialFingerprint,
            driveId: key.driveId,
            fileId: key.fileId,
            isTrashed: key.isTrashed
        )
        return nil
    }

    /// Attend la disponibilité d'une miniature récemment créée. Le travail est
    /// annulable et chaque tentative passe par le cache/dédoublonnage normal.
    /// Une fenêtre complète de réessais infructueuse inscrit la clé dans le
    /// cache négatif : les appels suivants renvoient nil sans retester
    /// pendant la TTL (les posters vidéo longs retrouvent une chance après).
    func thumbnailWhenAvailable(
        driveId: Int,
        fileId: Int,
        isTrashed: Bool = false,
        includeImmediateAttempt: Bool = true
    ) async -> UIImage? {
        let key = Self.key(driveId: driveId, fileId: fileId, isTrashed: isTrashed)

        // Absence récemment établie : ne pas relancer la boucle de réessais.
        if let failedAt = recentFailures[key], Date().timeIntervalSince(failedAt) < failureRetryTTL {
            return nil
        }

        let delays = includeImmediateAttempt
            ? uploadedMediaRetryDelays
            : Array(uploadedMediaRetryDelays.dropFirst())
        for delay in delays {
            guard !Task.isCancelled, Self.isCurrentCredential(key) else { return nil }
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return nil
                }
            }
            if let image = await thumbnail(for: key) {
                // Succès (poster enfin généré) : l'absence n'est plus d'actualité.
                recentFailures[key] = nil
                return image
            }
        }

        guard Self.isCurrentCredential(key) else { return nil }
        markAsFailed(key)
        return nil
    }

    /// Inscrit une clé dans le cache négatif en bornant sa taille.
    private func markAsFailed(_ key: Key) {
        // Éviction FIFO simple : la table ne peut pas croître sans limite.
        if recentFailures.count >= failureCacheLimit, recentFailures[key] == nil {
            if let oldest = recentFailures.min(by: { $0.value < $1.value })?.key {
                recentFailures.removeValue(forKey: oldest)
            }
        }
        recentFailures[key] = Date()
    }

    /// Amorce la génération des miniatures dès la confirmation de l'upload,
    /// y compris si l'utilisateur quitte le dossier avant son affichage.
    func primeUploadedThumbnail(driveId: Int, fileId: Int) async {
        _ = await thumbnailWhenAvailable(driveId: driveId, fileId: fileId)
    }

    /// Préchargement discret avec régulation de concurrence et abandon des requêtes lointaines.
    func prefetch(driveId: Int, fileIds: [Int], isTrashed: Bool = false) {
        let credentialFingerprint = Self.currentCredentialFingerprint()
        var newestKeys: [Key] = []
        for fileId in fileIds {
            let key = Key(
                credentialFingerprint: credentialFingerprint,
                driveId: driveId,
                fileId: fileId,
                isTrashed: isTrashed
            )
            guard inFlight[key] == nil,
                  Self.memory.object(forKey: key.nsString) == nil,
                  !disk.hasEntry(
                      credentialFingerprint: credentialFingerprint,
                      driveId: driveId,
                      fileId: fileId,
                      isTrashed: isTrashed
                  )
            else { continue }
            if !newestKeys.contains(key) {
                newestKeys.append(key)
            }
        }

        // La dernière position visible remplace les anciennes demandes encore
        // en attente. Le téléchargement déjà commencé peut finir, mais aucune
        // longue file de miniatures hors écran ne subsiste.
        // Chaque clé garde sa session et son propre `isTrashed` : deux contextes
        // ne réutilisent jamais la même demande ou le mauvais endpoint.
        pendingPrefetchKeys = Array(newestKeys.prefix(maxPendingPrefetch))

        schedulePrefetchWorker()
    }

    /// Annule les téléchargements anticipés en attente. Les miniatures déjà
    /// présentes dans les caches mémoire ou disque ne sont pas supprimées.
    func cancelPrefetch() {
        pendingPrefetchKeys.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    private func schedulePrefetchWorker() {
        guard prefetchTask == nil else { return }
        prefetchTask = Task { [weak self] in
            while let next = await self?.popNextPrefetchKey() {
                guard !Task.isCancelled else { break }
                _ = await self?.thumbnail(for: next)
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
            schedulePrefetchWorker()
        }
    }

    /// Décodage et enregistrement disque exécutés hors de l'executor de
    /// l'actor (`nonisolated` async = global concurrent executor) : pendant
    /// un défilement rapide, chaque décodage JPEG et chaque écriture fichier
    /// ne sérialisent plus les autres chargements derrière eux.
    private nonisolated func decodeAndStore(_ data: Data, key: Key) async -> UIImage? {
        guard !data.isEmpty, Self.isCurrentCredential(key) else { return nil }
        // Vérifier le contenu avant de le placer dans le cache. Une page
        // d'erreur renvoyée à tort en 2xx ne doit jamais devenir une
        // absence de miniature persistante.
        guard let image = UIImage.decode(data) else { return nil }
        guard Self.isCurrentCredential(key) else { return nil }
        // Les données validées sont conservées sans ré-encodage CPU.
        disk.store(
            data: data,
            credentialFingerprint: key.credentialFingerprint,
            driveId: key.driveId,
            fileId: key.fileId,
            isTrashed: key.isTrashed
        )
        return image
    }

    private func fetch(key: Key) async -> UIImage? {
        guard !Task.isCancelled, Self.isCurrentCredential(key) else { return nil }
        do {
            let data = try await throttler.withPermit {
                try Task.checkCancellation()
                guard Self.isCurrentCredential(key) else { throw CancellationError() }
                return try await service.thumbnailData(
                    driveId: key.driveId,
                    fileId: key.fileId,
                    isTrashed: key.isTrashed
                )
            }
            guard !Task.isCancelled, Self.isCurrentCredential(key) else { return nil }
            return await decodeAndStore(data, key: key)
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
        recentFailures.removeAll()
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
