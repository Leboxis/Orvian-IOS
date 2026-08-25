import AVFoundation
import Combine
import Foundation

/// Résout à la volée (et met en cache) la durée, l'orientation et la définition des vidéos.
///
/// L'API kDrive ne renvoyant pas ces informations dans la liste des fichiers,
/// on les lit dans le fichier lui-même via les URL temporaires déjà en cache.
@MainActor
final class MediaMetadataStore: ObservableObject {
    static let shared = MediaMetadataStore()

    struct Info {
        let duration: Double
        let orientation: FileFilters.Orientation
        let maximumDimension: CGFloat

        /// UHD (3 840 × 2 160), DCI 4K et les vidéos portrait équivalentes.
        var is4KOrAbove: Bool { maximumDimension >= 3_840 }
    }

    /// Incrémenté à chaque résolution : les vues observent cette propriété
    /// pour se rafraîchir au fur et à mesure que les métadonnées arrivent.
    @Published private(set) var revision = 0

    private var cache: [Int: Info] = [:]
    /// Les resolutions en cours sont partagees : une grille qui attend les
    /// metadonnees ne doit pas paginer parce qu'une autre tache les a deja lancees.
    private var inFlight: [Int: Task<Void, Never>] = [:]

    private init() {}

    func info(for fileId: Int) -> Info? {
        cache[fileId]
    }

    /// Résout en arrière-plan les métadonnées des vidéos d'une liste,
    /// par petits lots pour ne pas saturer le réseau.
    func resolveAll(driveId: Int, items: [DriveFile]) async {
        let pending = items.filter { $0.isVideo && cache[$0.id] == nil }
        let batch = 8
        var index = 0
        while index < pending.count {
            let chunk = Array(pending[index..<min(index + batch, pending.count)])
            var resolvedAny = false
            await withTaskGroup(of: Bool.self) { group in
                for file in chunk {
                    group.addTask {
                        await self.resolve(driveId: driveId, fileId: file.id)
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

    /// Les identifiants des vidéos d'une liste dont les métadonnées manquent
    /// encore (ni en cache, ni en cours de résolution). Utilisé par la grille
    /// pour ne relancer la résolution que s'il y a du nouveau travail.
    func unresolvedVideoIDs(in items: [DriveFile]) -> Set<Int> {
        Set(
            items.lazy
                .filter { [self] in $0.isVideo && cache[$0.id] == nil && inFlight[$0.id] == nil }
                .map(\.id)
        )
    }

    private func resolve(driveId: Int, fileId: Int) async -> Bool {
        guard cache[fileId] == nil else { return false }
        if let task = inFlight[fileId] {
            _ = await task.value
            return false
        }

        // Réutilise l'asset déjà préparé par VideoAssetCache (URL temporaire en
        // cache, option de durée précise) : pas de second AVURLAsset ni de
        // double sondage réseau pour la même vidéo.
        let task = Task<Void, Never> { [self] in
            defer { inFlight.removeValue(forKey: fileId) }
            guard let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: fileId) else { return }
            guard let duration = try? await asset.load(.duration) else { return }
            let properties = await videoProperties(of: asset)
            cache[fileId] = Info(
                duration: duration.seconds,
                orientation: properties.orientation,
                maximumDimension: properties.maximumDimension
            )
        }
        inFlight[fileId] = task
        await task.value
        return cache[fileId] != nil
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
