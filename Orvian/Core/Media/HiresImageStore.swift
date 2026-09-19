import UIKit
import ImageIO

/// Images haute résolution pour la visionneuse : téléchargées via l'URL
/// temporaire publique de kDrive puis décodées par ImageIO.
///
/// - Le fichier est téléchargé sur disque (`URLSession.download`) puis décodé
///   directement depuis son URL : les octets compressés ne transittent jamais
///   par la mémoire et aucune copie intermédiaire n'est conservée.
/// - Le décodage se fait au **niveau affichage** (`displayImage`) : ImageIO
///   réduit pendant la décompression, à la dimension de l'écran en pixels.
///   L'ancien décodage « taille native du capteur » produisait une image de
///   48 Mpx (≈ 195 Mo décodés) que SwiftUI réduisait ensuite sur le GPU à
///   chaque frame ; le cache, limité à trois entrées, était vidé par une seule
///   photo et ne conservait donc presque rien pour les pages voisines.
/// - `fullResolutionImage` reste disponible pour le zoom, à la demande
///   seulement, sous sa propre clé de cache.
/// - Un régulateur borne la concurrence (un décodage à la fois) pour ne jamais
///   saturer le réseau ni la mémoire lorsque plusieurs pages du pager
///   demandent leur image en même temps.
actor HiresImageStore {
    static let shared = HiresImageStore()

    private let memory = NSCache<NSString, UIImage>()
    /// Clé = `"\(niveau)-\(driveId)-\(fileId)"` : comme pour les autres caches,
    /// le drive est inclus pour ne jamais confondre deux drives qui
    /// partageraient le même identifiant de fichier, et le niveau (affichage à
    /// telle taille, ou natif) pour qu'un aperçu réduit ne soit jamais servi
    /// comme image pleine résolution.
    private struct ImageResult: @unchecked Sendable {
        let image: UIImage?
    }
    private let requests = SharedRequests<String, ImageResult>()
    /// Une image pleine résolution au plus en vol : au-delà, les demandes
    /// patientent dans une file asynchrone sans bloquer aucun thread.
    private let throttler = AsyncThrottler(maxConcurrent: 1)

    init() {
        // Une image « niveau affichage » (≈ 1× l'écran en pixels) pèse quelques
        // mégaoctets décodés : le cache sert désormais plusieurs pages voisines
        // au lieu d'être vidé par une seule photo pleine résolution. Le plafond
        // de coût reste volontairement bas : l'enveloppe mémoire d'un conteneur
        // comme LiveContainer est plus contrainte que celle d'une app native.
        memory.countLimit = 6
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    private func memoryKey(level: String, driveId: Int, fileId: Int) -> NSString {
        "\(level)-\(driveId)-\(fileId)" as NSString
    }

    /// Image prête à afficher (`maximumPixelSize` en pixels, côté long).
    ///
    /// Plusieurs niveaux peuvent coexister pour un même fichier : la clé de
    /// cache inclut la taille demandée, sinon un aperçu réduit serait servi
    /// comme image « pleine résolution » (ou l'inverse).
    func displayImage(driveId: Int, fileId: Int, maximumPixelSize: CGFloat) async -> UIImage? {
        let pixels = max(1, maximumPixelSize.rounded())
        return await image(
            driveId: driveId,
            fileId: fileId,
            maximumPixelSize: pixels,
            level: "display-\(Int(pixels))"
        )
    }

    /// Image à la résolution native du fichier : réservée aux usages qui ne
    /// peuvent pas se contenter du niveau affichage.
    func fullResolutionImage(driveId: Int, fileId: Int) async -> UIImage? {
        await image(driveId: driveId, fileId: fileId, maximumPixelSize: nil, level: "full")
    }

    private func image(
        driveId: Int,
        fileId: Int,
        maximumPixelSize: CGFloat?,
        level: String
    ) async -> UIImage? {
        let memoryKey = memoryKey(level: level, driveId: driveId, fileId: fileId)
        let taskKey = "\(level)-\(driveId)-\(fileId)"
        if let cached = memory.object(forKey: memoryKey) {
            return cached
        }
        do {
            let result = try await requests.value(for: taskKey) { [throttler] in
                try Task.checkCancellation()
                guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId) else {
                    return ImageResult(image: nil)
                }
                return ImageResult(image: await Self.downloadDecode(
                    url: url,
                    maximumPixelSize: maximumPixelSize,
                    throttler: throttler
                ))
            }
            guard !Task.isCancelled, let image = result.image else { return nil }
            memory.setObject(image, forKey: memoryKey, cost: Int(image.size.width * image.size.height * image.scale * 4))
            return image
        } catch {
            return nil
        }
    }

    /// Téléchargement vers un fichier temporaire puis décodage par ImageIO à la
    /// taille demandée. Téléchargement **et** décodage partagent le régulateur :
    /// deux décompressions simultanées (page courante + page suivante du pager)
    /// formaient un pic mémoire d'environ 400 Mo pour du 48 Mpx, auquel
    /// s'ajoutaient les images déjà en cache. Un seul décodage à la fois borne
    /// le pic sans dégrader la qualité affichée. Le fichier source est supprimé
    /// dans tous les cas ; l'annulation de la tâche interrompt le transfert
    /// réseau.
    nonisolated private static func downloadDecode(
        url: URL,
        maximumPixelSize: CGFloat?,
        throttler: AsyncThrottler
    ) async -> UIImage? {
        struct DownloadRejected: Error {}
        do {
            let image: UIImage? = try await throttler.withPermit {
                try Task.checkCancellation()
                let (downloadedURL, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    throw DownloadRejected()
                }
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                return Self.decode(fromFile: downloadedURL, maximumPixelSize: maximumPixelSize)
            }
            return image
        } catch {
            return nil
        }
    }

    /// Décodage depuis le fichier téléchargé.
    ///
    /// `maximumPixelSize` non nul réduit l'image **pendant** la décompression
    /// (ImageIO redimensionne avant de matérialiser les pixels), au lieu de
    /// décoder la pleine résolution puis de la laisser réduire par le GPU à
    /// chaque affichage. `kCGImageSourceCreateThumbnailFromImageAlways` avec
    /// transformation applique l'orientation EXIF ; `ShouldCacheImmediately`
    /// force la décompression hors du thread appelant.
    nonisolated static func decode(fromFile fileURL: URL, maximumPixelSize: CGFloat?) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maximumPixelSize, maximumPixelSize > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = maximumPixelSize
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
