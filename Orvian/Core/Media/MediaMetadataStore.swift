import AVFoundation
import Combine
import Foundation

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
final class MediaMetadataStore: ObservableObject {
    struct Info: Codable {
        let duration: Double
        let orientation: FileFilters.Orientation
        let maximumDimension: CGFloat

        /// UHD (3 840 × 2 160), DCI 4K et les vidéos portrait équivalentes.
        var is4KOrAbove: Bool { maximumDimension >= 3_840 }
    }

    /// Entrée persistée : les informations + les empreintes du fichier au
    /// moment de l'analyse, pour détecter une vidéo remplacée.
    private struct PersistedEntry: Codable {
        let info: Info
        let size: Int?
        let lastModifiedAt: Double?
        let resolvedAt: Date
    }

    /// Incrémenté à chaque résolution : les vues observent cette propriété
    /// pour se rafraîchir au fur et à mesure que les métadonnées arrivent.
    @Published private(set) var revision = 0

    /// Cache mémoire de session, indexé par identifiant de fichier.
    private var cache: [Int: Info] = [:]
    /// Cache disque, indexé `driveId-fileId` (deux drives peuvent partager un
    /// même identifiant de fichier).
    private var entries: [String: PersistedEntry] = [:]
    private var persistenceLoaded = false
    private var pendingSaveTask: Task<Void, Never>?
    /// Limite douce du cache disque ; l'écriture écarte les entrées les plus
    /// anciennes au-delà (des milliers de vidéos restent couvertes).
    private static let persistedEntryLimit = 6_000

    /// Les resolutions en cours sont partagees : une grille qui attend les
    /// metadonnees ne doit pas paginer parce qu'une autre tache les a deja lancees.
    private var inFlight: [Int: Task<Void, Never>] = [:]

    private init() {}

    func info(for fileId: Int) -> Info? {
        cache[fileId]
    }

    // MARK: - Persistance

    private static func persistenceURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orvian", isDirectory: true)
            .appendingPathComponent("video-metadata.json")
    }

    private func persistenceKey(driveId: Int, fileId: Int) -> String {
        "\(driveId)-\(fileId)"
    }

    private func ensurePersistenceLoaded() {
        guard !persistenceLoaded else { return }
        persistenceLoaded = true
        guard let data = try? Data(contentsOf: Self.persistenceURL()),
              let decoded = try? JSONDecoder().decode([String: PersistedEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func scheduleSave() {
        // Coalescence : chaque nouvelle demande remplace la précédente tant
        // qu'elle n'a pas démarré ; l'écriture atomique garantit qu'aucun
        // fichier partiel ne peut être lu.
        pendingSaveTask?.cancel()
        let snapshot = entries
        pendingSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            Self.write(entries: snapshot, to: Self.persistenceURL())
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
        ensurePersistenceLoaded()
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
        ensurePersistenceLoaded()

        var pending: [DriveFile] = []
        var promotedAny = false
        for file in items where file.isVideo {
            guard cache[file.id] == nil else { continue }
            if let restored = persistedInfo(driveId: driveId, file: file) {
                // Promotion mémoire : la grille retrouve l'information via
                // `info(for:)` sans repasser par le disque à chaque rendu.
                cache[file.id] = restored
                promotedAny = true
                continue
            }
            pending.append(file)
        }
        if promotedAny {
            revision += 1
        }

        let batch = 8
        var index = 0
        while index < pending.count {
            let chunk = Array(pending[index..<min(index + batch, pending.count)])
            var resolvedAny = false
            await withTaskGroup(of: Bool.self) { group in
                for file in chunk {
                    group.addTask {
                        await self.resolve(driveId: driveId, file: file)
                    }
                }
                for await resolved in group {
                    resolvedAny = resolvedAny || resolved
                }
            }
            // Un seul signal de rafraichissement par lot termine : la grille
            // se re-trie une fois par lot au lieu d'une fois par video.
            if resolvedAny {
                revision += 1
            }
            index += batch
        }
    }

    /// Empreinte stable et bon marché des vidéos d'une liste dont les
    /// métadonnées manquent encore (mémoire, disque valide ou analyse en vol).
    /// Somme additive + comptage : aucun tableau, aucun tri, aucune chaîne —
    /// la clé `.task(id:)` de la grille n'est plus reconstruite en O(n log n)
    /// à chaque rendu.
    func unresolvedVideoFingerprint(in items: [DriveFile], driveId: Int) -> (count: Int, checksum: Int) {
        ensurePersistenceLoaded()
        var count = 0
        var checksum = 0
        for file in items where file.isVideo {
            guard cache[file.id] == nil,
                  persistedInfo(driveId: driveId, file: file) == nil,
                  inFlight[file.id] == nil
            else { continue }
            count += 1
            checksum = checksum &+ file.id
        }
        return (count, checksum)
    }

    private func resolve(driveId: Int, file: DriveFile) async -> Bool {
        guard cache[file.id] == nil else { return false }
        if let task = inFlight[file.id] {
            _ = await task.value
            return false
        }

        // Réutilise l'asset déjà préparé par VideoAssetCache (URL temporaire
        // en cache) : pas de second AVURLAsset ni de double sondage réseau
        // pour la même vidéo. La durée du moov est assez précise pour le tri.
        let task = Task<Void, Never> { [self] in
            defer { inFlight.removeValue(forKey: file.id) }
            guard let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: file.id) else { return }
            guard let duration = try? await asset.load(.duration) else { return }
            let properties = await videoProperties(of: asset)
            let info = Info(
                duration: duration.seconds,
                orientation: properties.orientation,
                maximumDimension: properties.maximumDimension
            )
            cache[file.id] = info
            entries[persistenceKey(driveId: driveId, fileId: file.id)] = PersistedEntry(
                info: info,
                size: file.size,
                lastModifiedAt: file.lastModifiedAt,
                resolvedAt: Date()
            )
            scheduleSave()
        }
        inFlight[file.id] = task
        await task.value
        return cache[file.id] != nil
    }

    private func videoProperties(
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
