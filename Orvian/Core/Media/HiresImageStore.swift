import UIKit
import ImageIO

/// Images haute résolution pour la visionneuse : téléchargées via l'URL
/// temporaire publique puis sous-échantillonnées avec ImageIO pour limiter
/// la mémoire (jamais de bitmap 4K décompressée inutilement).
actor HiresImageStore {
    static let shared = HiresImageStore()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [Int: Task<UIImage?, Never>] = [:]

    init() {
        memory.countLimit = 30
        memory.totalCostLimit = 150 * 1024 * 1024
    }

    func image(driveId: Int, fileId: Int, maxPixelSize: Int = 2560) async -> UIImage? {
        if let cached = memory.object(forKey: "\(fileId)" as NSString) {
            return cached
        }
        if let task = inFlight[fileId] {
            return await task.value
        }
        let task = Task<UIImage?, Never> { [self] in
            defer { inFlight[fileId] = nil }
            guard !Task.isCancelled,
                  let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId) else {
                return nil
            }
            guard let image = await downloadAndDownsample(url: url, maxPixelSize: maxPixelSize) else {
                return nil
            }
            memory.setObject(image, forKey: "\(fileId)" as NSString, cost: Int(image.size.width * image.size.height * 4))
            return image
        }
        inFlight[fileId] = task
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
