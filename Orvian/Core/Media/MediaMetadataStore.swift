import AVFoundation
import Combine
import Foundation
import ImageIO

/// Résout à la volée (et met en cache) les métadonnées des médias : durée et
/// dimensions des vidéos, dimensions en pixels des images.
///
/// L'API kDrive ne renvoyant pas ces informations dans la liste des fichiers,
/// on les lit dans le fichier lui-même via les URL temporaires déjà en cache :
/// AVFoundation pour les vidéos, en-tête ImageIO pour les images.
@MainActor
final class MediaMetadataStore: ObservableObject {
    static let shared = MediaMetadataStore()

    struct Info {
        /// Durée en secondes ; nil pour les images.
        let duration: Double?
        let orientation: FileFilters.Orientation
        let pixelWidth: Int
        let pixelHeight: Int

        /// Surface en pixels : clé de tri du mode « Résolution »
        /// (une 4K 3840×2160 passe devant une 1080p, quel que soit le ratio).
        var pixelCount: Int { pixelWidth * pixelHeight }
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

    /// Résout en arrière-plan les métadonnées des médias d'une liste,
    /// par petits lots pour ne pas saturer le réseau.
    func resolveAll(driveId: Int, items: [DriveFile]) async {
        let pending = items.filter { ($0.isVideo || $0.isImage) && cache[$0.id] == nil && !inFlight.contains($0.id) }
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
                        await self.resolve(driveId: driveId, fileId: file.id, isVideo: file.isVideo)
                    }
                }
            }
            // Un seul signal de rafraîchissement par lot terminé : la grille
            // se re-trie une fois par lot au lieu d'une fois par média.
            revision += 1
            index += batch
        }
    }

    /// Les identifiants des médias d'une liste dont les métadonnées manquent
    /// encore (ni en cache, ni en cours de résolution). Utilisé par la grille
    /// pour ne relancer la résolution que s'il y a du nouveau travail.
    func unresolvedMediaIDs(in items: [DriveFile]) -> Set<Int> {
        Set(
            items.lazy
                .filter { [self] in ($0.isVideo || $0.isImage) && cache[$0.id] == nil && !inFlight.contains($0.id) }
                .map(\.id)
        )
    }

    private func resolve(driveId: Int, fileId: Int, isVideo: Bool) async {
        defer { inFlight.remove(fileId) }
        if isVideo {
            if let info = await resolveVideo(driveId: driveId, fileId: fileId) {
                cache[fileId] = info
            }
        } else if let info = await resolveImage(driveId: driveId, fileId: fileId) {
            cache[fileId] = info
        }
    }

    /// Vidéos : réutilise l'asset déjà préparé par VideoAssetCache (URL
    /// temporaire en cache, option de durée précise) : pas de second AVURLAsset
    /// ni de double sondage réseau pour la même vidéo.
    private func resolveVideo(driveId: Int, fileId: Int) async -> Info? {
        guard let asset = await VideoAssetCache.shared.asset(driveId: driveId, fileId: fileId) else { return nil }
        guard let duration = try? await asset.load(.duration) else { return nil }

        // Une vidéo sans piste lisible garde sa durée : dimensions à zéro,
        // elle sera simplement classée en fin de tri par résolution.
        var width = CGFloat.zero
        var height = CGFloat.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let transformed = Self.transformedDimensions(of: size, transform: transform)
            width = transformed.width
            height = transformed.height
        }
        return Info(
            duration: duration.seconds,
            orientation: Self.orientation(width: width, height: height),
            pixelWidth: Int(width),
            pixelHeight: Int(height)
        )
    }

    /// Images : ImageIO lit uniquement l'en-tête du fichier distant — quelques
    /// kilo-octets suffisent pour obtenir les dimensions sans télécharger la
    /// photo entière. L'IO synchrone part sur une file globale pour ne jamais
    /// bloquer un thread coopératif ni le MainActor.
    private func resolveImage(driveId: Int, fileId: Int) async -> Info? {
        guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.imageDimensions(at: url))
            }
        }
    }

    private nonisolated static func imageDimensions(at url: URL) -> Info? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let widthValue = properties[kCGImageSourcePixelWidth],
              let heightValue = properties[kCGImageSourcePixelHeight] else {
            return nil
        }
        // Les valeurs peuvent arriver en CFNumber non convertibles directement
        // en Int selon le format : passer par NSNumber garantit la conversion.
        guard let width = (widthValue as? NSNumber)?.intValue,
              let height = (heightValue as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return nil
        }
        return Info(
            duration: nil,
            orientation: orientation(width: width, height: height),
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private nonisolated static func transformedDimensions(
        of size: CGSize,
        transform: CGAffineTransform
    ) -> (width: CGFloat, height: CGFloat) {
        let transformed = size.applying(transform)
        return (abs(transformed.width), abs(transformed.height))
    }

    private nonisolated static func orientation(width: CGFloat, height: CGFloat) -> FileFilters.Orientation {
        let ratio = max(width, height) / max(min(width, height), 1)
        if ratio < 1.15 { return .square }
        return width > height ? .landscape : .portrait
    }
}
