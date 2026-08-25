import AVFoundation
import Foundation

/// Prépare les vidéos à partir des URLs temporaires signées de kDrive.
///
/// AVFoundation ne reçoit jamais le jeton kDrive : KDriveService obtient une
/// URL temporaire via MediaURLCache, puis AVURLAsset travaille directement
/// avec cette URL publique et limitée dans le temps.
@MainActor
final class VideoAssetCache {
    static let shared = VideoAssetCache()

    private struct Key: Hashable {
        let driveId: Int
        let fileId: Int
        let credentialFingerprint: Int
    }

    private let maximumEntries = 8
    private var assets: [Key: AVURLAsset] = [:]
    private var insertionOrder: [Key] = []
    private var prefetchTasks: [Key: Task<Void, Never>] = [:]
    private var refreshRequired: Set<Key> = []

    private init() {}

    /// Obtient une URL signée et prépare l'asset pour AVPlayer. La validation
    /// de la lisibilité est laissée à AVPlayer afin qu'un contrôle préalable
    /// trop strict ne bloque pas des formats que le lecteur sait décoder.
    func asset(driveId: Int, fileId: Int) async -> AVURLAsset? {
        let key = makeKey(driveId: driveId, fileId: fileId)
        if let asset = assets[key], !refreshRequired.contains(key) {
            return asset
        }

        let needsRefresh = refreshRequired.remove(key) != nil
        guard !Task.isCancelled else { return nil }
        let url = needsRefresh
            ? await MediaURLCache.shared.freshURL(driveId: driveId, fileId: fileId)
            : await MediaURLCache.shared.url(driveId: driveId, fileId: fileId)
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }

        // Pas d'option « durée précise » : elle force un parsing complet des
        // tables de samples avant la première frame, uniquement pour servir le
        // tri par durée des grilles. La durée issue du moov suffit largement.
        let asset = AVURLAsset(url: url)
        assets[key] = asset
        insertionOrder.removeAll { $0 == key }
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
                    do {
                        guard try await asset.load(.isPlayable) else {
                            throw PlaybackPreparationError.notPlayable
                        }
                    } catch {
                        self.invalidate(driveId: driveId, fileId: fileId)
                    }
                }
                self.prefetchTasks[key] = nil
            }
        }
    }

    func cancelPrefetch() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
    }

    /// Oublie l'asset et force la prochaine préparation à demander une
    /// nouvelle URL signée à Infomaniak.
    func invalidate(driveId: Int, fileId: Int) {
        let key = makeKey(driveId: driveId, fileId: fileId)
        prefetchTasks[key]?.cancel()
        prefetchTasks[key] = nil
        assets[key] = nil
        insertionOrder.removeAll { $0 == key }
        refreshRequired.insert(key)
        Task {
            await MediaURLCache.shared.invalidate(driveId: driveId, fileId: fileId)
        }
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

private enum PlaybackPreparationError: Error {
    case notPlayable
}
