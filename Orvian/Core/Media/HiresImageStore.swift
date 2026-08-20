import UIKit
import ImageIO

/// Images haute résolution pour la visionneuse : téléchargées via l'URL
/// temporaire publique puis sous-échantillonnées avec ImageIO pour limiter
/// la mémoire (jamais de bitmap décompressée au-delà du besoin réel :
/// 5120 px couvre la quasi-totalité des photos, pleine qualité 12-24 MP
/// et qualité quasi native pour les 48 MP).
actor HiresImageStore {
    static let shared = HiresImageStore()

    private let memory = NSCache<NSString, UIImage>()
    /// Clé = `"\(driveId)-\(fileId)"` : comme pour les autres caches, le drive
    /// est inclus pour ne jamais confondre deux drives qui partageraient le
    /// même identifiant de fichier.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        memory.countLimit = 12
        memory.totalCostLimit = 300 * 1024 * 1024
    }

    private func memoryKey(driveId: Int, fileId: Int) -> NSString {
        "\(driveId)-\(fileId)" as NSString
    }

    private func taskKey(driveId: Int, fileId: Int) -> String {
        "\(driveId)-\(fileId)"
    }

    func image(driveId: Int, fileId: Int, maxPixelSize: Int = 5120) async -> UIImage? {
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
            guard let image = await downloadAndDownsample(url: url, maxPixelSize: maxPixelSize) else {
                return nil
            }
            memory.setObject(image, forKey: memoryKey, cost: Int(image.size.width * image.size.height * 4))
            return image
        }
        inFlight[taskKey] = task
        return await task.value
    }

    private func downloadAndDownsample(url: URL, maxPixelSize: Int) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                return nil
            }
            return Self.downsample(data: data, maxPixelSize: maxPixelSize)
        } catch {
            return nil
        }
    }

    /// ImageIO : décodage direct à la taille cible, mémoire maîtrisée.
    nonisolated static func downsample(data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
