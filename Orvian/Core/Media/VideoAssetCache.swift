import AVFoundation
import Foundation

/// Prépare et conserve quelques ressources vidéo authentifiées proches de la
/// zone visible. Le cache est limité et n'est utilisé que si le réglage de
/// préchargement vidéo est actif.
@MainActor
final class VideoAssetCache {
    static let shared = VideoAssetCache()

    private struct Key: Hashable {
        let driveId: Int
        let fileId: Int
        let credentialFingerprint: Int
    }

    private let service = KDriveService()
    private let maximumEntries = 8
    private var assets: [Key: AVURLAsset] = [:]
    private var insertionOrder: [Key] = []
    private var prefetchTasks: [Key: Task<Void, Never>] = [:]

    private init() {}

    func asset(driveId: Int, fileId: Int) async -> AVURLAsset? {
        let key = makeKey(driveId: driveId, fileId: fileId)
        if let asset = assets[key] {
            return asset
        }

        guard let request = try? await service.videoPlaybackRequest(driveId: driveId, fileId: fileId),
              let url = request.url,
              let authorization = request.value(forHTTPHeaderField: "Authorization")
        else { return nil }

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": authorization]]
        )
        assets[key] = asset
        insertionOrder.append(key)
        trimIfNeeded()
        return asset
    }

    func prefetch(driveId: Int, fileIds: [Int]) {
        for fileId in fileIds {
            let key = makeKey(driveId: driveId, fileId: fileId)
            guard assets[key] == nil, prefetchTasks[key] == nil else { continue }

            prefetchTasks[key] = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                if let asset = await self.asset(driveId: driveId, fileId: fileId), !Task.isCancelled {
                    _ = try? await asset.load(.isPlayable)
                }
                self.prefetchTasks[key] = nil
            }
        }
    }

    func cancelPrefetch() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
    }

    /// Oublie une ressource qui a échoué pendant le traitement initial du
    /// média côté serveur afin que la tentative suivante reparte proprement.
    func invalidate(driveId: Int, fileId: Int) {
        let key = makeKey(driveId: driveId, fileId: fileId)
        prefetchTasks[key]?.cancel()
        prefetchTasks[key] = nil
        assets[key] = nil
        insertionOrder.removeAll { $0 == key }
    }

    private func makeKey(driveId: Int, fileId: Int) -> Key {
        Key(
            driveId: driveId,
            fileId: fileId,
            credentialFingerprint: TokenStore.current()?.hashValue ?? 0
        )
    }

    private func trimIfNeeded() {
        while insertionOrder.count > maximumEntries {
            let oldest = insertionOrder.removeFirst()
            assets[oldest] = nil
        }
    }
}
