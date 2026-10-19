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
        print("Video asset sharing and cancellation checks passed")
    }
}
