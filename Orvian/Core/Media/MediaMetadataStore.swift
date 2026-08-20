import AVFoundation
import Combine
import Foundation

/// Résout à la volée (et met en cache) la durée et l'orientation des vidéos.
///
/// L'API kDrive ne renvoyant pas ces informations dans la liste des fichiers,
/// on les lit dans le fichier lui-même via les URL temporaires déjà en cache.
@MainActor
final class MediaMetadataStore: ObservableObject {
    static let shared = MediaMetadataStore()

    struct Info {
        let duration: Double
        let orientation: FileFilters.Orientation
    }

    /// Incrémenté à chaque résolution : les vues observent cette propriété
    /// pour se rafraîchir au fur et à mesure que les métadonnées arrivent.
    @Published private(set) var revision = 0

    private var cache: [Int: Info] = [:]
    private var inFlight: Set<Int> = []

    private init() {}

    func info(for fileId: Int) -> Info? {
        cache[fileId]
    }

    /// Résout en arrière-plan les métadonnées des vidéos d'une liste,
    /// par petits lots pour ne pas saturer le réseau.
    func resolveAll(driveId: Int, items: [DriveFile]) async {
        let pending = items.filter { $0.isVideo && cache[$0.id] == nil && !inFlight.contains($0.id) }
        let batch = 4
        var index = 0
        while index < pending.count {
            let chunk = Array(pending[index..<min(index + batch, pending.count)])
            for file in chunk {
                inFlight.insert(file.id)
            }
            await withTaskGroup(of: Void.self) { group in
                for file in chunk {
                    group.addTask {
                        await self.resolve(driveId: driveId, fileId: file.id)
                    }
                }
            }
            index += batch
        }
    }

    private func resolve(driveId: Int, fileId: Int) async {
        defer { inFlight.remove(fileId) }
        // Réutilise l'URL temporaire déjà en cache (préchargements vidéo,
        // visionneuse…) : pas de nouvelle requête réseau si elle existe.
        guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId) else { return }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return }
        let orientation = await orientation(of: asset)
        cache[fileId] = Info(duration: duration.seconds, orientation: orientation)
        revision += 1
    }

    private func orientation(of asset: AVURLAsset) async -> FileFilters.Orientation {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return .landscape
        }
        let transformed = size.applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        let ratio = max(width, height) / max(min(width, height), 1)
        if ratio < 1.15 { return .square }
        return width > height ? .landscape : .portrait
    }
}