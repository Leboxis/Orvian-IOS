import Foundation
import CoreGraphics
import ImageIO

// Le test du décodeur ne fait aucun accès réseau.
actor MediaURLCache {
    static let shared = MediaURLCache()
    func url(driveId: Int, fileId: Int) async -> URL? { nil }
}

@main
struct GIFImageChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("animated.gif")
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, delay) in [0.1, 0.3].enumerated() {
            context.setFillColor(CGColor(red: CGFloat(index), green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            CGImageDestinationAddImage(destination, context.makeImage()!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        let decoded = GIFImageStore.decode(url)!
        precondition(decoded.frameCount == 2)
        precondition(decoded.loopCount == 0)
        precondition(abs(decoded.firstFrame.delay - 0.1) < 0.001)
        let second = await decoded.source.frame(at: 1)
        precondition(abs(second!.delay - 0.3) < 0.001)
        precondition(decoded.aspectRatio == 2)
        precondition(second!.image.width == 32 && second!.image.height == 16)
        let outOfBounds = await decoded.source.frame(at: 2)
        precondition(outOfBounds == nil)
        precondition(FileManager.default.fileExists(atPath: url.path))

        // Régression : 120 frames faisaient tomber l'ancien décodeur à ~323 px.
        // La première ET la dernière doivent maintenant conserver les 640 px.
        let longURL = directory.appendingPathComponent("long.gif")
        let largeContext = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let longDestination = CGImageDestinationCreateWithURL(longURL as CFURL,
            "com.compuserve.gif" as CFString, 120, nil)!
        for index in 0..<120 {
            largeContext.setFillColor(CGColor(red: CGFloat(index % 2), green: 0, blue: 1, alpha: 1))
            largeContext.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
            CGImageDestinationAddImage(longDestination, largeContext.makeImage()!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(longDestination))
        let longGIF = GIFImageStore.decode(longURL)!
        precondition(longGIF.frameCount == 120)
        precondition(longGIF.firstFrame.image.width == 640 && longGIF.firstFrame.image.height == 320)
        let lastFrame = await longGIF.source.frame(at: 119)
        precondition(lastFrame!.image.width == 640 && lastFrame!.image.height == 320)
        let repeatedFrame = await longGIF.source.frame(at: 1)
        precondition(repeatedFrame!.image.width == 640)

        let invalid = directory.appendingPathComponent("invalid.gif")
        try Data("not a GIF".utf8).write(to: invalid)
        precondition(GIFImageStore.decode(invalid) == nil)
        let png = directory.appendingPathComponent("static.png")
        let pngDestination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(pngDestination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(pngDestination))
        precondition(GIFImageStore.decode(png) == nil)
        print("GIF decoding checks passed")
    }
}
