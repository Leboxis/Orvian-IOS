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
    static func main() throws {
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
        precondition(decoded.frames.count == 2)
        precondition(decoded.loopCount == 0)
        precondition(abs(decoded.delays[0] - 0.1) < 0.001)
        precondition(abs(decoded.delays[1] - 0.3) < 0.001)
        precondition(abs(decoded.duration - 0.4) < 0.001)
        precondition(decoded.aspectRatio == 2)
        precondition(decoded.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } <= 48 * 1024 * 1024)

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
