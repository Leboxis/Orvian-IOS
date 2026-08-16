import Foundation

/// Cache session des URLs temporaires kDrive (pour AVPlayer et les images
/// haute résolution). Les URL sont publiques et signées : aucun en-tête
/// d'authentification n'est nécessaire côté AVFoundation.
actor MediaURLCache {
    static let shared = MediaURLCache()

    private var entries: [Int: (url: URL, expiresAt: Date)] = [:]
    private var inFlight: [Int: Task<URL?, Never>] = [:]
    private let service: KDriveService

    init(service: KDriveService = KDriveService()) {
        self.service = service
    }

    func url(driveId: Int, fileId: Int) async -> URL? {
        if let entry = entries[fileId], entry.expiresAt > Date().addingTimeInterval(30) {
            return entry.url
        }
        if let task = inFlight[fileId] {
            return await task.value
        }
        let task = Task<URL?, Never> { [self] in
            defer { inFlight[fileId] = nil }
            guard !Task.isCancelled else { return nil }
            do {
                let url = try await service.temporaryURL(driveId: driveId, fileId: fileId)
                entries[fileId] = (url, Date().addingTimeInterval(3300))
                return url
            } catch {
                return nil
            }
        }
        inFlight[fileId] = task
        return await task.value
    }

    /// Pré-résolution pour que le tap sur une vidéo démarre plus vite.
    func prefetch(driveId: Int, fileIds: [Int]) {
        for fileId in fileIds where inFlight[fileId] == nil && entries[fileId] == nil {
            let task = Task<URL?, Never> { [self] in
                defer { inFlight[fileId] = nil }
                guard !Task.isCancelled else { return nil }
                if let url = try? await service.temporaryURL(driveId: driveId, fileId: fileId) {
                    entries[fileId] = (url, Date().addingTimeInterval(3300))
                }
                return nil
            }
            inFlight[fileId] = task
        }
    }
}
