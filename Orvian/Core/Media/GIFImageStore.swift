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

    private struct Key: Hashable, Sendable {
        let driveId: Int
        let fileId: Int
        let credentialFingerprint: String?
        let sessionGeneration: UInt

        var memoryKey: NSString {
            "\(sessionGeneration)-\(credentialFingerprint ?? "signed-out")-\(driveId)-\(fileId)" as NSString
        }
    }

    private struct PendingImage {
        let id: UUID
        let task: Task<GIFImage?, Never>
    }

    private final class CachedImage: NSObject {
        let value: GIFImage

        init(_ value: GIFImage) {
            self.value = value
        }
    }

    typealias URLProvider = @Sendable (Int, Int) async -> URL?
    typealias Downloader = @Sendable (URL) async throws -> (localURL: URL, statusCode: Int?)

    private let memory = NSCache<NSString, CachedImage>()
    private var inFlight: [Key: PendingImage] = [:]
    private var observedCredentialFingerprint: String?
    private var hasObservedCredential = false
    private var sessionGeneration: UInt = 0
    private let credentialFingerprint: @Sendable () -> String?
    private let urlProvider: URLProvider
    private let downloader: Downloader

    init(
        maximumEntries: Int = 4,
        totalCostLimit: Int = 96 * 1024 * 1024,
        credentialFingerprint: @escaping @Sendable () -> String? = {
            TokenStore.credentialFingerprint()
        },
        urlProvider: @escaping URLProvider = { driveId, fileId in
            await MediaURLCache.shared.url(driveId: driveId, fileId: fileId)
        },
        downloader: @escaping Downloader = { url in
            let (localURL, response) = try await URLSession.shared.download(from: url)
            return (localURL, (response as? HTTPURLResponse)?.statusCode)
        }
    ) {
        memory.countLimit = max(1, maximumEntries)
        memory.totalCostLimit = max(1, totalCostLimit)
        self.credentialFingerprint = credentialFingerprint
        self.urlProvider = urlProvider
        self.downloader = downloader
    }

    func image(driveId: Int, fileId: Int) async -> GIFImage? {
        guard !Task.isCancelled else { return nil }
        let key = makeKey(driveId: driveId, fileId: fileId)
        if let cached = memory.object(forKey: key.memoryKey) {
            return cached.value
        }

        let pending: PendingImage
        if let existing = inFlight[key] {
            pending = existing
        } else {
            let id = UUID()
            let task = Task<GIFImage?, Never> { [weak self] in
                guard let self else { return nil }
                return await self.downloadImage(for: key)
            }
            pending = PendingImage(id: id, task: task)
            inFlight[key] = pending
        }

        // Attendre une tâche non structurée ne lui propage pas l'annulation du
        // consommateur : une autre page peut encore dépendre du même transfert.
        let image = await pending.task.value
        if inFlight[key]?.id == pending.id {
            inFlight[key] = nil
        }
        guard !Task.isCancelled, isCurrent(key) else { return nil }
        return image
    }

    /// Vide les objets réutilisables sans interrompre les téléchargements
    /// partagés. `NSCache` effectue aussi cette éviction sous pression mémoire.
    func purgeCache() {
        memory.removeAllObjects()
    }

    private func downloadImage(for key: Key) async -> GIFImage? {
        guard isCurrent(key),
              let url = await urlProvider(key.driveId, key.fileId),
              isCurrent(key) else { return nil }
        do {
            let download = try await downloader(url)
            // Transférer la propriété du fichier à la source si le GIF est valide.
            var retained = false
            defer { if !retained { try? FileManager.default.removeItem(at: download.localURL) } }
            guard let statusCode = download.statusCode,
                  (200..<300).contains(statusCode),
                  let image = Self.decode(download.localURL, ownsFile: true)
            else { return nil }
            retained = true
            guard isCurrent(key) else { return nil }
            let firstFrameCost = image.firstFrame.image.bytesPerRow * image.firstFrame.image.height
            memory.setObject(CachedImage(image), forKey: key.memoryKey, cost: firstFrameCost)
            return image
        } catch {
            return nil
        }
    }

    private func makeKey(driveId: Int, fileId: Int) -> Key {
        let credential = synchronizeCredential()
        return Key(
            driveId: driveId,
            fileId: fileId,
            credentialFingerprint: credential,
            sessionGeneration: sessionGeneration
        )
    }

    private func isCurrent(_ key: Key) -> Bool {
        let credential = synchronizeCredential()
        return key.credentialFingerprint == credential
            && key.sessionGeneration == sessionGeneration
    }

    /// Une transition de compte invalide aussi les anciennes générations du
    /// même credential (A -> B -> A), pas seulement les clés d'un autre token.
    private func synchronizeCredential() -> String? {
        let current = credentialFingerprint()
        if !hasObservedCredential || current != observedCredentialFingerprint {
            hasObservedCredential = true
            observedCredentialFingerprint = current
            sessionGeneration &+= 1
            memory.removeAllObjects()
        }
        return current
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
