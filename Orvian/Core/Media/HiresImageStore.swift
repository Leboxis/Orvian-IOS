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
/// - Deux transferts au maximum se chevauchent, avec un seul décodage à la
///   fois pour borner le pic de mémoire des pages voisines.
actor HiresImageStore {
    static let shared = HiresImageStore()

    private let memory = NSCache<NSString, UIImage>()
    private let pixelSizes = NSCache<NSString, NSValue>()
    /// Clé = `"\(niveau)-\(driveId)-\(fileId)"` : comme pour les autres caches,
    /// le drive est inclus pour ne jamais confondre deux drives qui
    /// partageraient le même identifiant de fichier, et le niveau (affichage à
    /// telle taille, ou natif) pour qu'un aperçu réduit ne soit jamais servi
    /// comme image pleine résolution.
    private struct ImageResult: @unchecked Sendable {
        let image: UIImage?
        var pixelSize: CGSize? = nil
    }
    private let requests = SharedRequests<String, ImageResult>()
    /// Les transferts peuvent se chevaucher sans multiplier les décodages.
    private let downloads = AsyncThrottler(maxConcurrent: 2)
    /// Une seule décompression en vol, y compris lors d'un zoom.
    private let throttler = AsyncThrottler(maxConcurrent: 1)

    init() {
        // Une image « niveau affichage » (≈ 1× l'écran en pixels) pèse quelques
        // mégaoctets décodés : le cache sert désormais plusieurs pages voisines
        // au lieu d'être vidé par une seule photo pleine résolution. Le plafond
        // de coût reste volontairement bas : l'enveloppe mémoire d'un conteneur
        // comme LiveContainer est plus contrainte que celle d'une app native.
        memory.countLimit = 6
        pixelSizes.countLimit = 24
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    private func memoryKey(level: String, driveId: Int, fileId: Int) -> NSString {
        "\(TokenStore.credentialFingerprint() ?? "signed-out")-\(level)-\(driveId)-\(fileId)" as NSString
    }

    func cachedOriginalPixelSize(driveId: Int, fileId: Int) -> CGSize? {
        pixelSizes.object(forKey: memoryKey(level: "dimensions", driveId: driveId, fileId: fileId))?.cgSizeValue
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
        let dimensionsKey = self.memoryKey(level: "dimensions", driveId: driveId, fileId: fileId)
        let credential = TokenStore.credentialFingerprint()
        let taskKey = memoryKey as String
        if let cached = memory.object(forKey: memoryKey) {
            return cached
        }
        do {
            let result = try await requests.value(for: taskKey) { [throttler, downloads] in
                try Task.checkCancellation()
                guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId) else {
                    return ImageResult(image: nil)
                }
                return await Self.downloadDecode(
                    url: url,
                    maximumPixelSize: maximumPixelSize,
                    throttler: throttler,
                    downloads: downloads
                )
            }
            guard !Task.isCancelled, credential == TokenStore.credentialFingerprint(), let image = result.image else { return nil }
            if let size = result.pixelSize { pixelSizes.setObject(NSValue(cgSize: size), forKey: dimensionsKey) }
            memory.setObject(image, forKey: memoryKey, cost: Int(image.size.width * image.size.height * image.scale * 4))
            return image
        } catch {
            return nil
        }
    }

    /// Téléchargement vers un fichier temporaire puis décodage par ImageIO à la
    /// taille demandée. Le réseau a deux places, le décodage une seule :
    /// deux décompressions simultanées (page courante + page suivante du pager)
    /// formaient un pic mémoire d'environ 400 Mo pour du 48 Mpx, auquel
    /// s'ajoutaient les images déjà en cache. Un seul décodage à la fois borne
    /// le pic sans dégrader la qualité affichée. Le fichier source est supprimé
    /// dans tous les cas ; l'annulation de la tâche interrompt le transfert
    /// réseau.
    nonisolated private static func downloadDecode(
        url: URL,
        maximumPixelSize: CGFloat?,
        throttler: AsyncThrottler,
        downloads: AsyncThrottler
    ) async -> ImageResult {
        struct DownloadRejected: Error {}
        do {
            let (downloadedURL, response) = try await downloads.withPermit {
                try Task.checkCancellation()
                return try await URLSession.shared.download(from: url)
            }
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { throw DownloadRejected() }
            let result: ImageResult = try await throttler.withPermit {
                try Task.checkCancellation()
                return ImageResult(image: Self.decode(fromFile: downloadedURL, maximumPixelSize: maximumPixelSize),
                                   pixelSize: Self.originalPixelSize(fromFile: downloadedURL))
            }
            return result
        } catch {
            return ImageResult(image: nil)
        }
    }

    nonisolated static func originalPixelSize(fromFile url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height.doubleValue, height: width.doubleValue)
            : CGSize(width: width.doubleValue, height: height.doubleValue)
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
