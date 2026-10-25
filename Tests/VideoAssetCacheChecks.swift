import Foundation

// Le script réunit ce fichier et le cache dans une même unité Swift : cette
// extension peut attendre les tâches privées sans ajouter d'API à l'app.
extension VideoAssetCache {
    var preparationTasksForTesting: [Task<Void, Never>] { Array(prefetchTasks.values) }
}

// Compilé avec le cache de production et des dépendances contrôlées par
// check_media_startup.py : aucun rendu, aucune connexion à kDrive.
@main
struct VideoAssetCacheChecks {
    @MainActor
    static func main() async {
        let cache = VideoAssetCache()
        let first = Task { await cache.asset(driveId: 1, fileId: 2) }
        let second = Task { await cache.asset(driveId: 1, fileId: 2) }
        while MediaURLCache.shared.waiters.count < 2 { await Task.yield() }
        MediaURLCache.shared.complete()
        let a = await first.value
        let b = await second.value
        precondition(a != nil && a === b, "Concurrent opens must share the prepared asset")
        let reused = await cache.asset(driveId: 1, fileId: 2)
        precondition(reused === a)
        precondition(MediaURLCache.shared.calls == 2, "Cache hit must not resolve another URL")

        // Un préchargement annulé ne doit pas invalider l'asset que le
        // lecteur actif est déjà en train d'utiliser.
        cache.prefetch(driveId: 1, fileIds: [3])
        while MediaURLCache.shared.waiters.isEmpty { await Task.yield() }
        MediaURLCache.shared.complete()
        while AVURLAsset.pendingLoads.isEmpty { await Task.yield() }
        let active = await cache.asset(driveId: 1, fileId: 3)
        let preparations = cache.preparationTasksForTesting
        cache.cancelPrefetch()
        AVURLAsset.pendingLoads.removeFirst().resume(throwing: CancellationError())
        for preparation in preparations { await preparation.value }
        precondition(MediaURLCache.shared.invalidations == 0)
        let afterCancellation = await cache.asset(driveId: 1, fileId: 3)
        precondition(active === afterCancellation)
        // An invalidation during URL resolution must reject that old request,
        // even after a newer request has consumed the refresh flag.
        let stale = Task { await cache.asset(driveId: 1, fileId: 4) }
        while MediaURLCache.shared.waiters.isEmpty { await Task.yield() }
        let staleURL = MediaURLCache.shared.waiters.removeFirst()
        MediaURLCache.shared.holdInvalidations = true
        cache.invalidate(driveId: 1, fileId: 4)
        var supersededStarted = false
        let superseded = Task {
            supersededStarted = true
            return await cache.asset(driveId: 1, fileId: 4)
        }
        while !supersededStarted || MediaURLCache.shared.invalidationWaiters.isEmpty { await Task.yield() }
        cache.invalidate(driveId: 1, fileId: 4)
        let replacement = Task { await cache.asset(driveId: 1, fileId: 4) }
        precondition(MediaURLCache.shared.waiters.isEmpty,
                     "Replacement URL resolution must wait for obsolete URL invalidation")
        MediaURLCache.shared.invalidationWaiters.removeFirst().resume()
        let supersededAsset = await superseded.value
        precondition(supersededAsset == nil)
        while MediaURLCache.shared.invalidationWaiters.isEmpty { await Task.yield() }
        precondition(MediaURLCache.shared.waiters.isEmpty,
                     "Stale invalidation cleanup must preserve the newer invalidation barrier")
        MediaURLCache.shared.holdInvalidations = false
        MediaURLCache.shared.invalidationWaiters.removeFirst().resume()
        while MediaURLCache.shared.waiters.isEmpty { await Task.yield() }
        MediaURLCache.shared.complete()
        let currentAsset = await replacement.value
        precondition(currentAsset != nil)
        staleURL.resume(returning: URL(string: "https://example.invalid/old-version"))
        let discarded = await stale.value
        precondition(discarded == nil, "An obsolete URL request must not republish its asset")
        let stillCurrent = await cache.asset(driveId: 1, fileId: 4)
        precondition(stillCurrent === currentAsset, "The replacement asset must remain cached")
        print("Video asset sharing, cancellation and invalidation checks passed")
    }
}
