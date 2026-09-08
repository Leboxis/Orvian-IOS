import Foundation
import CoreGraphics
import ImageIO

/// Frames décodées une seule fois, sans duplication pour représenter les délais.
struct GIFImage {
    let frames: [CGImage]
    let delays: [Double]
    let loopCount: Int
    var duration: Double { delays.reduce(0, +) }
    var aspectRatio: CGFloat { CGFloat(frames[0].width) / CGFloat(frames[0].height) }
}

/// Seule la page active demande une animation. Aucun cache ne retient ses frames.
actor GIFImageStore {
    static let shared = GIFImageStore()

    func image(driveId: Int, fileId: Int) async -> GIFImage? {
        guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId),
              !Task.isCancelled else { return nil }
        do {
            let (localURL, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: localURL) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return Self.decode(localURL)
        } catch {
            return nil
        }
    }

    nonisolated static func decode(_ url: URL) -> GIFImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif"
        else { return nil }
        let count = CGImageSourceGetCount(source)
        // Les fichiers excessifs ou invalides gardent leur aperçu statique.
        guard count > 0, count <= 2000 else { return nil }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loops = (gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue ?? 1
        // Budget conservateur de 48 Mo pour les frames, même pour un GIF long.
        let budget = 48 * 1024 * 1024
        let maxPixelSize = max(1, min(1280, Int(sqrt(Double(budget / count / 4)))))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        var frames: [CGImage] = []
        var delays: [Double] = []
        var cost = 0
        for index in 0..<count {
            guard !Task.isCancelled else { return nil }
            let frame: CGImage? = autoreleasepool {
                CGImageSourceCreateThumbnailAtIndex(source, index, options)
            }
            guard let frame else { return nil }
            cost += frame.bytesPerRow * frame.height
            guard cost <= budget else { return nil }
            let info = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let frameGIF = info?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let rawDelay = (frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (frameGIF?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            frames.append(frame)
            delays.append(rawDelay.isFinite && rawDelay > 0 ? max(0.02, rawDelay) : 0.1)
        }
        return GIFImage(frames: frames, delays: delays, loopCount: max(0, loops))
    }
}
