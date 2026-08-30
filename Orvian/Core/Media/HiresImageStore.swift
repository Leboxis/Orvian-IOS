import UIKit
import ImageIO

/// Images haute résolution pour la visionneuse : téléchargées via l'URL
/// temporaire publique de kDrive puis décodées par ImageIO.
///
/// - Le fichier est téléchargé sur disque (`URLSession.download`) puis décodé
///   directement depuis son URL : les octets compressés ne transittent jamais
///   par la mémoire et aucune copie intermédiaire n'est conservée.
/// - L'image originale est décodée en pleine résolution, sans réduction :
///   le zoom de la visionneuse reste net jusqu'au niveau natif du capteur.
/// - Un régulateur borne la concurrence (2 téléchargements simultanés) pour
///   ne jamais saturer le réseau ni la mémoire lorsque plusieurs pages du
///   pager demandent leur haute résolution en même temps.
actor HiresImageStore {
    static let shared = HiresImageStore()

    private let memory = NSCache<NSString, UIImage>()
    /// Clé = `"\(driveId)-\(fileId)"` : comme pour les autres caches, le drive
    /// est inclus pour ne jamais confondre deux drives qui partageraient le
    /// même identifiant de fichier.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Deux images pleine résolution au plus en vol : au-delà, les demandes
    /// patientent dans une file asynchrone sans bloquer aucun thread.
    private let throttler = AsyncThrottler(maxConcurrent: 2)

    init() {
        // Une photo pleine résolution occupe plusieurs dizaines de Mo décodée
        // (48 MP ≈ 195 Mo). Les limites sont volontairement basses : le pager
        // précharge la page suivante, chaque image décodée peut donc se
        // cumuler avec la précédente, et l'enveloppe mémoire d'un conteneur
        // comme LiveContainer est plus contrainte que celle d'une app native.
        memory.countLimit = 3
        memory.totalCostLimit = 192 * 1024 * 1024
    }

    private func memoryKey(driveId: Int, fileId: Int) -> NSString {
        "\(driveId)-\(fileId)" as NSString
    }

    private func taskKey(driveId: Int, fileId: Int) -> String {
        "\(driveId)-\(fileId)"
    }

    func image(driveId: Int, fileId: Int) async -> UIImage? {
        let memoryKey = memoryKey(driveId: driveId, fileId: fileId)
        let taskKey = taskKey(driveId: driveId, fileId: fileId)
        if let cached = memory.object(forKey: memoryKey) {
            return cached
        }
        if let task = inFlight[taskKey] {
            return await task.value
        }
        let task = Task<UIImage?, Never> { [self] in
            defer { inFlight[taskKey] = nil }
            guard !Task.isCancelled,
                  let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId) else {
                return nil
            }
            guard let image = await Self.downloadDecodeOriginal(url: url, throttler: throttler) else {
                return nil
            }
            memory.setObject(image, forKey: memoryKey, cost: Int(image.size.width * image.size.height * image.scale * 4))
            return image
        }
        inFlight[taskKey] = task
        return await task.value
    }

    /// Téléchargement vers un fichier temporaire puis décodage pleine
    /// résolution par ImageIO. Téléchargement **et** décodage partagent le
    /// régulateur : deux décompressions simultanées (page courante + page
    /// suivante du pager) formaient un pic mémoire d'environ 400 Mo pour du
    /// 48 MP, auquel s'ajoutaient les images déjà en cache. Un seul décodage
    /// à la fois borne le pic sans dégrader la qualité affichée. Le fichier
    /// source est supprimé dans tous les cas ; l'annulation de la tâche
    /// interrompt le transfert réseau.
    nonisolated private static func downloadDecodeOriginal(
        url: URL,
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
                return Self.decodeOriginal(fromFile: downloadedURL)
            }
            return image
        } catch {
            return nil
        }
    }

    /// Décodage complet de l'image originale depuis son fichier, à la taille
    /// native du capteur. `kCGImageSourceCreateThumbnailFromImageAlways` avec
    /// transformation applique l'orientation EXIF ; `ShouldCacheImmediately`
    /// force la décompression hors du thread appelant.
    nonisolated static func decodeOriginal(fromFile fileURL: URL) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
