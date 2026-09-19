import AVFoundation
import Foundation
import Observation

/// Durée, orientation et définition d'une vidéo, telles que lues dans le
/// fichier lui-même.
///
/// Type de premier niveau (et non imbriqué dans le store) : il traverse
/// l'isolation vers l'exécuteur d'arrière-plan qui lit le `moov`, puis revient
/// sous forme d'instantané.
struct VideoMetadataInfo: Codable, Sendable {
    let duration: Double
    let orientation: FileFilters.Orientation
    let maximumDimension: CGFloat

    /// UHD (3 840 × 2 160), DCI 4K et les vidéos portrait équivalentes.
    var is4KOrAbove: Bool { maximumDimension >= 3_840 }
}

/// Instantané des métadonnées vidéo d'un drive, lisible sans isolation.
///
/// `FileFilters.visible` (filtres puis tri de la liste entière) l'utilise à la
/// place du store : la table `fileId → Info` remplace une clé chaîne
/// « empreinte-drive-fichier » reconstruite pour chaque fichier comparé, et la
/// passe ne dépend plus d'un type `@MainActor`.
struct VideoMetadataSnapshot: Sendable {
    private let infos: [Int: VideoMetadataInfo]

    init(infos: [Int: VideoMetadataInfo] = [:]) {
        self.infos = infos
    }

    func info(for fileId: Int) -> VideoMetadataInfo? { infos[fileId] }
}

/// Demande de résolution transportée vers l'exécuteur d'arrière-plan : seules
/// des valeurs simples traversent, jamais le `DriveFile` complet. L'empreinte
/// de jeton voyage avec : un changement de compte pendant le vol ne doit jamais
/// attribuer une durée à un fichier d'un autre compte.
private struct VideoMetadataRequest: Sendable {
    let credentialFingerprint: String?
    let driveId: Int
    let fileId: Int
    let size: Int?
    let lastModifiedAt: Double?
}

/// Résout à la volée (et met en cache) la durée, l'orientation et la définition des vidéos.
///
/// L'API kDrive ne renvoyant pas ces informations dans la liste des fichiers,
/// on les lit dans le fichier lui-même via les URL temporaires déjà en cache.
///
/// Les résultats sont également persistés sur disque : sans cela, chaque
/// lancement de l'app re-chargeait le `moov` de toutes les vidéos via le
/// réseau juste pour trier par durée ou filtrer par orientation. Une entrée
/// persistée est invalidée automatiquement quand la taille ou la date de
/// modification du fichier changent (nouvelle version d'une vidéo).
@MainActor
@Observable
final class MediaMetadataStore {
    static let shared = MediaMetadataStore()

    /// Nom court conservé pour les usages internes (`MediaMetadataStore.Info`).
    typealias Info = VideoMetadataInfo

    /// Entrée persistée : les informations + les empreintes du fichier au
    /// moment de l'analyse, pour détecter une vidéo remplacée.
    private struct PersistedEntry: Codable {
        let info: Info
        let size: Int?
        let lastModifiedAt: Double?
        let resolvedAt: Date
    }

    /// Incrémenté à chaque lot de résolutions : les vues observent cette
    /// propriété pour se rafraîchir au fur et à mesure que les métadonnées
    /// arrivent. Le type est **incrémental** (jamais remis à zéro) : une
    /// résolution terminée après la construction d'un instantané est donc
    /// toujours signalée par une valeur différente, même si un autre drive a
    /// été ouvert entre-temps.
    private(set) var revision = 0

    /// Cache mémoire isolé par empreinte du jeton, drive et fichier.
    ///
    /// `@ObservationIgnored` : ces dictionnaires sont lus par les passes de
    /// filtrage (`snapshot`) **pendant l'évaluation des corps de vues** ; les
    /// suivre invaliderait la grille à chaque vidéo résolue. Les vues se
    /// rafraîchissent par `revision`, un seul signal par lot.
    @ObservationIgnored private var cache: [String: Info] = [:]
    /// Résolutions en cours, par clé de persistance : la grille et le pager
    /// peuvent appeler `resolveAll` en même temps, une seule analyse doit
    /// partir pour une même vidéo.
    @ObservationIgnored private var inFlightKeys: Set<String> = []
    /// Cache disque, indexé `credential-driveId-fileId` (deux drives peuvent partager un
    /// même identifiant de fichier).
    @ObservationIgnored private var entries: [String: PersistedEntry] = [:]
    private var persistenceLoaded = false
    private var persistenceLoadTask: Task<[String: PersistedEntry], Never>?
    private var pendingSaveTask: Task<Void, Never>?
    /// Limite douce du cache disque ; l'écriture écarte les entrées les plus
    /// anciennes au-delà (des milliers de vidéos restent couvertes).
    private static let persistedEntryLimit = 6_000

    private let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.persistenceURL()
    }

    func info(driveId: Int, for fileId: Int) -> Info? {
        cache[persistenceKey(driveId: driveId, fileId: fileId)]
    }

    /// Instantané des métadonnées connues pour les vidéos d'une liste, destiné
    /// aux passes de filtrage/tri (`FileFilters.visible`).
    ///
    /// La table disque valide comble le délai d'une frame pendant lequel une
    /// résolution terminée en arrière-plan n'a pas encore été promue en
    /// mémoire : la liste ne repasse pas par un état « analyse en cours » alors
    /// que l'information est déjà disponible.
    func snapshot(driveId: Int, items: [DriveFile]) -> VideoMetadataSnapshot {
        // Préfixe construit une fois : une clé chaîne par vidéo, mais sans
        // relire l'empreinte du trousseau pour chacune.
        let prefix = persistencePrefix(
            credential: TokenStore.credentialFingerprint() ?? "signed-out",
            driveId: driveId
        )
        var infos: [Int: Info] = [:]
        infos.reserveCapacity(items.count)
        for file in items where file.isVideo {
            let key = prefix + String(file.id)
            if let info = cache[key] {
                infos[file.id] = info
            } else if let restored = persistedInfo(driveId: driveId, file: file) {
                infos[file.id] = restored
            }
        }
        return VideoMetadataSnapshot(infos: infos)
    }

    // MARK: - Persistance

    nonisolated private static func persistenceURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orvian", isDirectory: true)
            .appendingPathComponent("video-metadata.json")
    }

    /// Clé de session : une entrée n'est jamais partagée entre deux comptes.
    private func persistenceKey(credential: String, driveId: Int, fileId: Int) -> String {
        persistencePrefix(credential: credential, driveId: driveId) + String(fileId)
    }

    private func persistencePrefix(credential: String, driveId: Int) -> String {
        "\(credential)-\(driveId)-"
    }

    private func persistenceKey(driveId: Int, fileId: Int) -> String {
        persistenceKey(
            credential: TokenStore.credentialFingerprint() ?? "signed-out",
            driveId: driveId,
            fileId: fileId
        )
    }

    /// Vrai si cette version du fichier est déjà connue (cache mémoire, entrée
    /// disque encore valable) ou déjà en cours d'analyse par un autre écran.
    private func isResolved(credential: String, driveId: Int, file: DriveFile) -> Bool {
        let key = persistenceKey(credential: credential, driveId: driveId, fileId: file.id)
        return cache[key] != nil
            || inFlightKeys.contains(key)
            || persistedInfo(driveId: driveId, file: file) != nil
    }

    private func ensurePersistenceLoaded() async {
        guard !persistenceLoaded else { return }
        let task: Task<[String: PersistedEntry], Never>
        if let existing = persistenceLoadTask {
            task = existing
        } else {
            let source = storageURL
            task = Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: source),
                      let decoded = try? JSONDecoder().decode([String: PersistedEntry].self, from: data)
                else { return [:] }
                return decoded
            }
            persistenceLoadTask = task
        }
        let decoded = await task.value
        guard !persistenceLoaded else { return }
        entries.merge(decoded) { current, _ in current }
        persistenceLoaded = true
        persistenceLoadTask = nil
    }

    private func scheduleSave() {
        // Le snapshot n'est créé qu'après la période de coalescence. Le prendre
        // avant chaque délai forçait une copie du dictionnaire à la résolution
        // de chaque vidéo suivante.
        pendingSaveTask?.cancel()
        let destination = storageURL
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.entries
            await Task.detached(priority: .utility) {
                Self.write(entries: snapshot, to: destination)
            }.value
        }
    }

    nonisolated private static func write(entries: [String: PersistedEntry], to url: URL) {
        var payload = entries
        if payload.count > persistedEntryLimit {
            let kept = payload
                .sorted { $0.value.resolvedAt > $1.value.resolvedAt }
                .prefix(persistedEntryLimit / 2)
            payload = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Informations valides pour ce fichier exactement : une entrée disque
    /// dont la taille ou la date de modification ne correspondent plus est
    /// ignorée (la vidéo a été remplacée par une autre version).
    private func persistedInfo(driveId: Int, file: DriveFile) -> Info? {
        guard let entry = entries[persistenceKey(driveId: driveId, fileId: file.id)] else {
            return nil
        }
        if let fileSize = file.size, let entrySize = entry.size, fileSize != entrySize {
            return nil
        }
        if let modified = file.lastModifiedAt,
           let entryModified = entry.lastModifiedAt,
           modified != entryModified {
            return nil
        }
        return entry.info
    }

    // MARK: - Résolution

    /// Résout en arrière-plan les métadonnées des vidéos d'une liste,
    /// par petits lots pour ne pas saturer le réseau. Les entrées déjà
    /// connues (mémoire ou disque valide) sont servies sans aucun appel
    /// réseau ; seules les vidéos réellement inconnues sont analysées.
    func resolveAll(driveId: Int, items: [DriveFile]) async {
        await ensurePersistenceLoaded()
        let credential = TokenStore.credentialFingerprint()

        var pending: [DriveFile] = []
        var promotedAny = false
        // Une seule lecture de l'empreinte pour toute la passe : chaque clé
        // chaîne « empreinte-drive-fichier » construite par fichier relisait le
        // trousseau.
        let sessionCredential = credential ?? "signed-out"
        for file in items where file.isVideo {
            let key = persistenceKey(credential: sessionCredential, driveId: driveId, fileId: file.id)
            guard cache[key] == nil else { continue }
            if let restored = persistedInfo(driveId: driveId, file: file) {
                // Promotion mémoire : la grille retrouve l'information via
                // `info(for:)` sans repasser par le disque à chaque rendu.
                cache[key] = restored
                promotedAny = true
                continue
            }
            pending.append(file)
        }
        if promotedAny {
            revision += 1
        }

        // Lots de 4 (et non 8) : chaque résolution lit le `moov` via le réseau.
        // Huit sondages parallèles affament le lecteur actif quand le pager
        // s'ouvre avec un tri durée ou un filtre 4K pendant une lecture.
        let batch = 4
        var index = 0
        while index < pending.count {
            guard !Task.isCancelled, credential == TokenStore.credentialFingerprint() else { return }
            let chunk = Array(pending[index..<min(index + batch, pending.count)])
            var claimedKeys: [String] = []
            let requests = chunk.compactMap { file -> VideoMetadataRequest? in
                guard !isResolved(credential: sessionCredential, driveId: driveId, file: file) else {
                    return nil
                }
                // Réservation avant le lancement : la grille et le pager peuvent
                // appeler `resolveAll` en même temps, une seule analyse doit
                // partir pour une même vidéo (l'ancien `inFlight` le garantissait).
                let key = persistenceKey(credential: sessionCredential, driveId: driveId, fileId: file.id)
                guard !inFlightKeys.contains(key) else { return nil }
                inFlightKeys.insert(key)
                claimedKeys.append(key)
                return VideoMetadataRequest(
                    credentialFingerprint: credential,
                    driveId: driveId,
                    fileId: file.id,
                    size: file.size,
                    lastModifiedAt: file.lastModifiedAt
                )
            }
            if !requests.isEmpty {
                var resolved: [(request: VideoMetadataRequest, info: Info)] = []
                await withTaskGroup(of: (VideoMetadataRequest, Info?).self) { group in
                    for request in requests {
                        group.addTask { (request, await Self.resolve(request)) }
                    }
                    for await (request, info) in group {
                        guard let info else { continue }
                        resolved.append((request, info))
                    }
                }
                // La lecture du `moov` s'est faite hors du MainActor ; la
                // promotion en mémoire revient ici, dans l'isolation du store,
                // une fois le groupe terminé — réussites comme échecs : une
                // réservation jamais libérée exclurait la vidéo de toute
                // relance ultérieure.
                for key in claimedKeys {
                    inFlightKeys.remove(key)
                }
                for entry in resolved {
                    promote(entry.info, request: entry.request)
                }
                // Un seul signal de rafraichissement par lot termine : la grille
                // se re-trie une fois par lot au lieu d'une fois par video.
                if !resolved.isEmpty {
                    revision &+= 1
                }
            }
            index += batch
        }
    }

    /// Résolution d'une vidéo exécutée **hors du MainActor** : la lecture du
    /// `moov` (réseau) et des pistes ne tient plus le fil principal, où elle
    /// retardait le défilement et la lecture en cours. Seul un `Info`
    /// (`Sendable`) remonte : aucun objet d'AVFoundation ne traverse
    /// l'isolation.
    nonisolated private static func resolve(_ request: VideoMetadataRequest) async -> Info? {
        // Réutilise l'asset déjà préparé par VideoAssetCache (URL temporaire
        // en cache) : pas de second AVURLAsset ni de double sondage réseau
        // pour la même vidéo. La durée du moov est assez précise pour le tri.
        guard let asset = await VideoAssetCache.shared.asset(driveId: request.driveId, fileId: request.fileId) else {
            return nil
        }
        guard let duration = try? await asset.load(.duration) else { return nil }
        let properties = await videoProperties(of: asset)
        guard !Task.isCancelled else { return nil }
        return Info(
            duration: duration.seconds,
            orientation: properties.orientation,
            maximumDimension: properties.maximumDimension
        )
    }

    /// Promotion d'une résolution terminée en arrière-plan.
    ///
    /// - La session doit être celle qui a lancé l'analyse : un changement de
    ///   compte pendant le vol n'attribue jamais une durée au fichier d'un
    ///   autre compte (l'ancien code revalidait la clé à l'écriture).
    /// - L'entrée est écrite sans condition : une entrée disque **périmée**
    ///   (taille ou date ne correspondant plus) est précisément la raison pour
    ///   laquelle la vidéo est repartie en analyse — la garder l'aurait
    ///   maintenue inconnue pour toujours.
    private func promote(_ info: Info, request: VideoMetadataRequest) {
        guard request.credentialFingerprint == TokenStore.credentialFingerprint() else { return }
        let key = persistenceKey(
            credential: request.credentialFingerprint ?? "signed-out",
            driveId: request.driveId,
            fileId: request.fileId
        )
        cache[key] = info
        entries[key] = PersistedEntry(
            info: info,
            size: request.size,
            lastModifiedAt: request.lastModifiedAt,
            resolvedAt: Date()
        )
        scheduleSave()
    }

    /// Propriétés de la piste vidéo, lues sans isolateur : seules des valeurs
    /// numériques (`FileFilters.Orientation`, `CGFloat`) sont retournées.
    nonisolated private static func videoProperties(
        of asset: AVURLAsset
    ) async -> (orientation: FileFilters.Orientation, maximumDimension: CGFloat) {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return (.landscape, 0)
        }
        let transformed = size.applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        let ratio = max(width, height) / max(min(width, height), 1)
        let orientation: FileFilters.Orientation
        if ratio < 1.15 {
            orientation = .square
        } else {
            orientation = width > height ? .landscape : .portrait
        }
        return (orientation, max(width, height))
    }
}
