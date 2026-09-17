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
/// - classe l'échec avant de le mémoriser : une absence **prouvée** par le
///   serveur (404/410, corps vide) est retenue plusieurs minutes, une panne
///   passagère (réseau, timeout, 5xx) quelques secondes seulement ;
/// - ne barre jamais le cache disque : une miniature déjà écrite (session
///   précédente, préchargement d'un autre écran) est servie même après un
///   échec réseau, puisque le marqueur ne concerne que le réseau ;
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

    /// Cache négatif borné (politique dans `ThumbnailFailureLedger`) : une
    /// absence prouvée par le serveur y reste plusieurs minutes, une panne
    /// passagère quelques secondes. Les marqueurs ne concernent que le réseau :
    /// une miniature déjà présente en mémoire ou sur disque fait toujours foi.
    private var failures = ThumbnailFailureLedger()
    /// Dernier échec observé par clé, en attente de classification. Le type
    /// d'erreur n'est transformé en cache négatif qu'à la fin d'une fenêtre de
    /// réessais : un 404 pendant la génération du poster d'un import récent ne
    /// doit pas condamner la miniature dès la première tentative.
    private var lastFailures: [Key: (outcome: FetchOutcome, at: Date)] = [:]
    private let lastFailureLimit = 512

    /// Nature d'un échec de téléchargement, avant mémorisation.
    private enum FetchOutcome {
        /// Le serveur a répondu qu'il n'a pas (encore) de miniature : 404/410
        /// ou corps vide. Un média importé peut en générer une plus tard.
        case absent
        /// Panne passagère (réseau, timeout, 429, 5xx).
        case transient
    }

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

        // Cache négatif : la clé n'est écartée que si le disque n'a rien à
        // servir. Une miniature déjà écrite (session précédente, préchargement
        // d'un autre écran) doit être affichée même après un échec réseau.
        if failures.isBlocked(key.nsString), !hasDiskEntry(key) {
            return nil
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
        failures.clear(key.nsString)
        lastFailures[key] = nil
        return image
    }

    /// La clé a-t-elle déjà une miniature sur disque ? Consulté par le cache
    /// négatif, qui ne doit jamais masquer une lecture locale possible.
    private func hasDiskEntry(_ key: Key) -> Bool {
        disk.hasEntry(
            credentialFingerprint: key.credentialFingerprint,
            driveId: key.driveId,
            fileId: key.fileId,
            isTrashed: key.isTrashed
        )
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
    /// À la fin d'une fenêtre de réessais sans résultat, l'échec est classé :
    /// absence prouvée par le serveur (mémorisée durablement) ou panne
    /// passagère (écartée quelques secondes). Sans classification, une carte
    /// réapparue ne relance plus 8 tentatives sur ~60 s.
    func thumbnailWhenAvailable(
        driveId: Int,
        fileId: Int,
        isTrashed: Bool = false,
        includeImmediateAttempt: Bool = true,
        shouldRetry: Bool = true
    ) async -> UIImage? {
        let key = Self.key(driveId: driveId, fileId: fileId, isTrashed: isTrashed)

        // Clé écartée (absence mémorisée ou panne récente) : ne pas relancer la
        // boucle de réessais. Une miniature présente en mémoire ou sur disque
        // est servie par `thumbnail(for:)`, jamais bloquée par ce marqueur.
        if failures.isBlocked(key.nsString) {
            return nil
        }
        guard shouldRetry else {
            // Aucune boucle de réessais pour un fichier ancien : l'échec de la
            // tentative directe est classé selon sa preuve. Rien n'est décidé
            // sans observation récente.
            classifyFailure(key)
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
                failures.clear(key.nsString)
                lastFailures[key] = nil
                return image
            }
        }

        guard Self.isCurrentCredential(key) else { return nil }
        classifyFailure(key)
        return nil
    }

    /// Inscrit l'échec observé pour cette clé, puis oublie l'observation.
    /// Seule une absence prouvée par le serveur est mémorisée durablement ;
    /// une panne passagère n'écarte la clé que quelques secondes, afin qu'une
    /// coupure réseau ne condamne jamais la miniature pendant cinq minutes.
    private func classifyFailure(_ key: Key) {
        guard let observed = lastFailures[key] else { return }
        lastFailures[key] = nil
        switch observed.outcome {
        case .absent:
            failures.markAbsent(key.nsString)
        case .transient:
            failures.markTransientFailure(key.nsString)
        }
    }

    /// Mémorise la nature de l'échec, en attendant la fin de la fenêtre de
    /// réessais (`classifyFailure`) ou la prochaine tentative directe.
    private func recordFailure(_ outcome: FetchOutcome, for key: Key) {
        if lastFailures.count >= lastFailureLimit, lastFailures[key] == nil,
           let oldest = lastFailures.min(by: { $0.value.at < $1.value.at })?.key {
            lastFailures[oldest] = nil
        }
        lastFailures[key] = (outcome, Date())
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
                  !hasDiskEntry(key)
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
            // Un corps vide est une réponse du serveur, pas une panne : la
            // miniature n'existe (encore) pas pour ce fichier.
            guard !data.isEmpty else {
                recordFailure(.absent, for: key)
                return nil
            }
            return await decodeAndStore(data, key: key)
        } catch is CancellationError {
            return nil
        } catch {
            // L'échec est classé mais pas encore mémorisé : juste après un
            // upload, kDrive peut répondre 404 quelques secondes avant que la
            // miniature soit générée. La classification ne devient un marqueur
            // qu'à la fin d'une fenêtre de réessais (voir `classifyFailure`).
            recordFailure(Self.classify(error), for: key)
            return nil
        }
    }

    /// Une absence est prouvée quand le serveur répond 404/410 : il n'a
    /// réellement aucune miniature pour ce fichier. Tout le reste (réseau
    /// coupé, timeout, 429, 5xx) est passager et sera retenté.
    private static func classify(_ error: Error) -> FetchOutcome {
        guard let apiError = error as? APIError,
              case let .http(status, _, _) = apiError,
              status == 404 || status == 410
        else { return .transient }
        return .absent
    }

    // MARK: - Maintenance

    func purgeDiskCache() {
        Self.memory.removeAllObjects()
        pendingPrefetchKeys.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
        failures.removeAll()
        lastFailures.removeAll()
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
