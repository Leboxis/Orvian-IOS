import UIKit

/// Pipeline de miniatures : mémoire → disque → réseau.
///
/// - dédoublonne les requêtes en vol (une seule par fichier/taille) ;
/// - mémorise les « pas de miniature » pour ne pas re-demander ;
/// - toute la décompression se fait hors du thread principal (actor) ;
/// - l'annulation s'appuie sur la `Task` de l'appelant (`.task` SwiftUI).
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let memory = NSCache<NSString, UIImage>()
    private let disk: DiskImageCache
    private let service: KDriveService
    private var inFlight: [Key: Task<UIImage?, Never>] = [:]

    private struct Key: Hashable {
        let driveId: Int
        let fileId: Int
        let pixels: Int

        var nsString: NSString { "\(driveId)-\(fileId)-\(pixels)" as NSString }
    }

    init(service: KDriveService = KDriveService(), disk: DiskImageCache = .init()) {
        self.service = service
        self.disk = disk
        memory.countLimit = 600
        memory.totalCostLimit = 80 * 1024 * 1024
    }

    /// Miniature pour une carte ; nil si le fichier n'en a pas ou si annulé.
    /// `isTrashed` : les fichiers de la corbeille utilisent l'endpoint dédié.
    func thumbnail(driveId: Int, fileId: Int, pixels: Int = DS.thumbnailPixels, isTrashed: Bool = false) async -> UIImage? {
        let key = Key(driveId: driveId, fileId: fileId, pixels: pixels)

        if let cached = memory.object(forKey: key.nsString) {
            return cached
        }
        if disk.hasEntry(driveId: driveId, fileId: fileId, pixels: pixels) {
            if let image = disk.loadImage(driveId: driveId, fileId: fileId, pixels: pixels) {
                memory.setObject(image, forKey: key.nsString, cost: image.estimatedByteSize)
                return image
            }
            return nil // marqueur « pas de miniature » déjà sur disque
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [self] in
            defer { inFlight[key] = nil }
            return await fetch(key: key, isTrashed: isTrashed)
        }
        inFlight[key] = task
        let image = await task.value
        if !Task.isCancelled, let image {
            memory.setObject(image, forKey: key.nsString, cost: image.estimatedByteSize)
        }
        return image
    }

    /// Préchargement discret (cartes suivantes, vidéos à venir).
    func prefetch(driveId: Int, fileIds: [Int], pixels: Int = DS.thumbnailPixels, isTrashed: Bool = false) {
        for fileId in fileIds {
            let key = Key(driveId: driveId, fileId: fileId, pixels: pixels)
            guard inFlight[key] == nil,
                  memory.object(forKey: key.nsString) == nil,
                  !disk.hasEntry(driveId: driveId, fileId: fileId, pixels: pixels)
            else { continue }
            let task = Task<UIImage?, Never> { [self] in
                defer { inFlight[key] = nil }
                return await fetch(key: key, isTrashed: isTrashed)
            }
            inFlight[key] = task
        }
    }

    private func fetch(key: Key, isTrashed: Bool) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        do {
            let data = try await service.thumbnailData(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels, isTrashed: isTrashed)
            guard !data.isEmpty, let image = UIImage.decode(data) else {
                disk.storeMarker(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
                return nil
            }
            disk.store(image: image, driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
            return image
        } catch is CancellationError {
            return nil
        } catch {
            // Erreur réseau/HTTP ponctuelle : pas de marqueur, on réessaiera.
            if let apiError = error as? APIError, case let .http(status, _, _) = apiError, status == 404 {
                disk.storeMarker(driveId: key.driveId, fileId: key.fileId, pixels: key.pixels)
            }
            return nil
        }
    }

    // MARK: - Maintenance

    func purgeDiskCache() {
        memory.removeAllObjects()
        disk.purge()
    }

    func diskCacheSize() -> Int {
        disk.totalSize()
    }
}

private extension UIImage {
    /// Décompression hors écran : évite les à-coups de LazyVGrid au scroll.
    static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = image.size
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.preparingForDisplay()
    }

    var estimatedByteSize: Int {
        Int(size.width * size.height * 4)
    }
}
