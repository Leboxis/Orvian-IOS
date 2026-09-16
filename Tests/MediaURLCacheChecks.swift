extension MediaURLCache {
    func countForTesting() -> Int { entries.count }
    func expireForTesting() {
        entries = entries.mapValues { Entry(url: $0.url, expiresAt: .distantPast, lastAccess: $0.lastAccess) }
    }
}

@main struct MediaURLCacheChecks {
    static func main() async {
        let cache = MediaURLCache()
        for id in 0..<300 { _ = await cache.url(driveId: 1, fileId: id) }
        let count = await cache.countForTesting()
        precondition(count == 256, "Long sessions must remain bounded")
        let beforeHit = await URLCalls.shared.count
        _ = await cache.url(driveId: 1, fileId: 299)
        let afterHit = await URLCalls.shared.count
        precondition(beforeHit == afterHit, "Recent URLs must be reused")
        await cache.expireForTesting()
        _ = await cache.url(driveId: 1, fileId: 299)
        let remaining = await cache.countForTesting()
        precondition(remaining == 1, "Expired URLs must be removed without revisiting each file")
        await cache.clear(credentialFingerprint: "other-account")
        let preserved = await cache.countForTesting()
        precondition(preserved == 1, "A delayed old-account purge must preserve the new account")
        await cache.clear(credentialFingerprint: "account-a")
        let cleared = await cache.countForTesting()
        precondition(cleared == 0)
        print("Media URL capacity, expiry, reuse and account purge checks passed")
    }
}
