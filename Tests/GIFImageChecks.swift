import Foundation
import CoreGraphics
import ImageIO

// Le test du décodeur ne fait aucun accès réseau.
actor MediaURLCache {
    static let shared = MediaURLCache()
    func url(driveId: Int, fileId: Int) async -> URL? { nil }
}

enum TokenStore {
    static func credentialFingerprint() -> String? { "test-default" }
}

private enum GIFCheckError: Error {
    case unknownFile
    case requestTimedOut
}

private actor GIFDownloadHarness {
    private let sources: [Int: URL]
    private let delay: UInt64
    private var requestCounts: [Int: Int] = [:]
    private var failuresRemaining: [Int: Int] = [:]

    init(sources: [Int: URL], delay: UInt64 = 0) {
        self.sources = sources
        self.delay = delay
    }

    func remoteURL(driveId: Int, fileId: Int) -> URL? {
        URL(string: "https://example.invalid/\(driveId)/\(fileId).gif")
    }

    func failNext(fileId: Int) {
        failuresRemaining[fileId, default: 0] += 1
    }

    func download(_ remoteURL: URL) async throws -> (localURL: URL, statusCode: Int?) {
        guard let fileId = Int(remoteURL.deletingPathExtension().lastPathComponent),
              let source = sources[fileId] else { throw GIFCheckError.unknownFile }
        requestCounts[fileId, default: 0] += 1
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orvian-gif-check-\(UUID().uuidString).gif")
        try FileManager.default.copyItem(at: source, to: localURL)
        if let remaining = failuresRemaining[fileId], remaining > 0 {
            failuresRemaining[fileId] = remaining - 1
            return (localURL, 503)
        }
        return (localURL, 200)
    }

    func requestCount(fileId: Int) -> Int {
        requestCounts[fileId, default: 0]
    }

    func waitForRequest(fileId: Int) async throws {
        for _ in 0..<200 {
            if requestCounts[fileId, default: 0] > 0 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw GIFCheckError.requestTimedOut
    }
}

private final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String?) {
        self.value = value
    }

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: String?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
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

        // A -> B -> A réutilise la source (et donc son fichier temporaire)
        // sans second téléchargement de A.
        let cacheHarness = GIFDownloadHarness(sources: [1: url, 2: url])
        let cacheStore = GIFImageStore(
            maximumEntries: 2,
            credentialFingerprint: { "session-a" },
            urlProvider: { driveId, fileId in
                await cacheHarness.remoteURL(driveId: driveId, fileId: fileId)
            },
            downloader: { try await cacheHarness.download($0) }
        )
        let firstA = await cacheStore.image(driveId: 10, fileId: 1)
        let firstB = await cacheStore.image(driveId: 10, fileId: 2)
        let secondA = await cacheStore.image(driveId: 10, fileId: 1)
        precondition(firstA != nil && firstB != nil)
        precondition(secondA?.id == firstA?.id)
        let cachedASecondFrame = await secondA?.source.frame(at: 1)
        precondition(cachedASecondFrame?.image.width == 32)
        let firstACount = await cacheHarness.requestCount(fileId: 1)
        precondition(firstACount == 1)
        let otherDriveA = await cacheStore.image(driveId: 11, fileId: 1)
        let isolatedDriveCount = await cacheHarness.requestCount(fileId: 1)
        precondition(otherDriveA != nil && otherDriveA?.id != firstA?.id)
        precondition(isolatedDriveCount == 2)
        await cacheStore.purgeCache()
        let reloadedA = await cacheStore.image(driveId: 10, fileId: 1)
        let reloadedACount = await cacheHarness.requestCount(fileId: 1)
        precondition(reloadedA != nil)
        precondition(reloadedACount == 3)

        // Deux consommateurs partagent un transfert. Annuler le premier ne
        // doit ni annuler le second ni publier un résultat au premier.
        let sharedHarness = GIFDownloadHarness(sources: [3: url], delay: 120_000_000)
        let sharedStore = GIFImageStore(
            credentialFingerprint: { "session-a" },
            urlProvider: { driveId, fileId in
                await sharedHarness.remoteURL(driveId: driveId, fileId: fileId)
            },
            downloader: { try await sharedHarness.download($0) }
        )
        let cancelledCaller = Task { await sharedStore.image(driveId: 10, fileId: 3) }
        try await sharedHarness.waitForRequest(fileId: 3)
        let survivingCaller = Task { await sharedStore.image(driveId: 10, fileId: 3) }
        cancelledCaller.cancel()
        let survivingImage = await survivingCaller.value
        let cancelledImage = await cancelledCaller.value
        let sharedRequestCount = await sharedHarness.requestCount(fileId: 3)
        precondition(survivingImage != nil)
        precondition(cancelledImage == nil)
        precondition(sharedRequestCount == 1)

        // Un échec n'est pas conservé : la prochaine demande peut réussir.
        let retryHarness = GIFDownloadHarness(sources: [4: url])
        await retryHarness.failNext(fileId: 4)
        let retryStore = GIFImageStore(
            credentialFingerprint: { "session-a" },
            urlProvider: { driveId, fileId in
                await retryHarness.remoteURL(driveId: driveId, fileId: fileId)
            },
            downloader: { try await retryHarness.download($0) }
        )
        let failedImage = await retryStore.image(driveId: 10, fileId: 4)
        let retriedImage = await retryStore.image(driveId: 10, fileId: 4)
        let retryRequestCount = await retryHarness.requestCount(fileId: 4)
        precondition(failedImage == nil)
        precondition(retriedImage != nil)
        precondition(retryRequestCount == 2)

        // Une réponse de l'ancienne session ne peut pas alimenter la nouvelle,
        // même si elle termine après le changement de credential.
        let credential = CredentialBox("session-a")
        let sessionHarness = GIFDownloadHarness(sources: [5: url], delay: 120_000_000)
        let sessionStore = GIFImageStore(
            credentialFingerprint: { credential.read() },
            urlProvider: { driveId, fileId in
                await sessionHarness.remoteURL(driveId: driveId, fileId: fileId)
            },
            downloader: { try await sessionHarness.download($0) }
        )
        let staleRequest = Task { await sessionStore.image(driveId: 10, fileId: 5) }
        try await sessionHarness.waitForRequest(fileId: 5)
        credential.set("session-b")
        let currentRequest = Task { await sessionStore.image(driveId: 10, fileId: 5) }
        let currentImage = await currentRequest.value
        let staleImage = await staleRequest.value
        let cachedCurrentImage = await sessionStore.image(driveId: 10, fileId: 5)
        let currentSessionRequestCount = await sessionHarness.requestCount(fileId: 5)
        precondition(currentImage != nil)
        precondition(staleImage == nil)
        precondition(cachedCurrentImage?.id == currentImage?.id)
        precondition(currentSessionRequestCount == 2)
        credential.set("session-a")
        let restoredSessionImage = await sessionStore.image(driveId: 10, fileId: 5)
        let restoredSessionRequestCount = await sessionHarness.requestCount(fileId: 5)
        precondition(restoredSessionImage != nil)
        precondition(restoredSessionRequestCount == 3)

        print("GIF decoding and store checks passed")
    }
}
