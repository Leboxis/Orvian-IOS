import Foundation
import CoreGraphics
import ImageIO

struct GIFFrame {
    let image: CGImage
    let delay: Double
}

/// L'original reste sur disque ; seule la première frame est conservée ici.
struct GIFImage {
    let id = UUID()
    let firstFrame: GIFFrame
    let frameCount: Int
    let loopCount: Int
    let source: GIFFrameSource
    var aspectRatio: CGFloat {
        CGFloat(firstFrame.image.width) / CGFloat(firstFrame.image.height)
    }
}

/// Accès sérialisé à ImageIO, hors MainActor. Pas de tableau de frames décodées.
actor GIFFrameSource {
    private let source: CGImageSource
    private let ownedURL: URL?

    init(source: CGImageSource, ownedURL: URL?) {
        self.source = source
        self.ownedURL = ownedURL
    }

    deinit {
        if let ownedURL { try? FileManager.default.removeItem(at: ownedURL) }
    }

    func frame(at index: Int) -> GIFFrame? {
        guard !Task.isCancelled, index >= 0, index < CGImageSourceGetCount(source) else { return nil }
        return Self.decodeFrame(source, at: index)
    }

    nonisolated static func decodeFrame(_ source: CGImageSource, at index: Int) -> GIFFrame? {
        autoreleasepool {
            // Le cache de la source est désactivé ; décompresser maintenant pour
            // éviter de reporter le travail sur le thread d'affichage.
            guard let image = CGImageSourceCreateImageAtIndex(source, index,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            defer { CGImageSourceRemoveCacheAtIndex(source, index) }
            let info = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = info?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let rawDelay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            let delay = rawDelay.isFinite && rawDelay > 0 ? max(0.02, rawDelay) : 0.1
            return GIFFrame(image: image, delay: delay)
        }
    }
}

actor GIFImageStore {
    static let shared = GIFImageStore()

    func image(driveId: Int, fileId: Int) async -> GIFImage? {
        guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: fileId),
              !Task.isCancelled else { return nil }
        do {
            let (localURL, response) = try await URLSession.shared.download(from: url)
            // Transférer la propriété du fichier à la source si le GIF est valide.
            var retained = false
            defer { if !retained { try? FileManager.default.removeItem(at: localURL) } }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let image = Self.decode(localURL, ownsFile: true)
            retained = image != nil
            return image
        } catch {
            return nil
        }
    }

    nonisolated static func decode(_ url: URL, ownsFile: Bool = false) -> GIFImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif",
              CGImageSourceGetCount(source) > 0,
              let firstFrame = GIFFrameSource.decodeFrame(source, at: 0)
        else { return nil }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loops = (gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue ?? 1
        return GIFImage(firstFrame: firstFrame, frameCount: CGImageSourceGetCount(source),
            loopCount: max(0, loops), source: GIFFrameSource(source: source, ownedURL: ownsFile ? url : nil))
    }
}
