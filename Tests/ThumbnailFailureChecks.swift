import Foundation

@main
struct ThumbnailFailureChecks {
    static func main() {
        // Horloge injectable : aucun contrôle ne dépend de l'horloge réelle.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let absentKey = "fp|1|normal|42"

        // 1. Une absence prouvée écarte la clé pendant la TTL longue.
        var ledger = ThumbnailFailureLedger(absenceTTL: 300, transientTTL: 30, limit: 512)
        ledger.markAbsent(absentKey, now: start)
        precondition(ledger.isBlocked(absentKey, now: start.addingTimeInterval(299)))
        precondition(!ledger.isBlocked(absentKey, now: start.addingTimeInterval(300)),
                     "Une absence prouvée doit expirer après sa TTL")
        precondition(ledger.blockedReason(absentKey, now: start.addingTimeInterval(10)) == .absent)

        // 2. Une panne passagère ne condamne pas la miniature : TTL courte,
        //    puis la clé est de nouveau demandable.
        ledger.markTransientFailure(absentKey, now: start)
        precondition(ledger.isBlocked(absentKey, now: start.addingTimeInterval(29)))
        precondition(!ledger.isBlocked(absentKey, now: start.addingTimeInterval(30)),
                     "A transient outage must not outlive its short TTL")
        precondition(ledger.blockedReason(absentKey, now: start) == .transient)

        // 3. Une miniature obtenue annule le marqueur.
        ledger.markAbsent(absentKey, now: start)
        ledger.clear(absentKey)
        precondition(!ledger.isBlocked(absentKey, now: start))

        // 4. La table reste bornée : la clé la plus ancienne est évincée.
        ledger.removeAll()
        let bounded = ThumbnailFailureLedger(absenceTTL: 300, transientTTL: 30, limit: 3)
        var filling = bounded
        for index in 0..<4 {
            filling.markAbsent("clé-\(index)", now: start.addingTimeInterval(Double(index)))
        }
        precondition(!filling.isBlocked("clé-0", now: start.addingTimeInterval(4)),
                     "Oldest entries must be evicted when the limit is reached")
        precondition(filling.isBlocked("clé-1", now: start.addingTimeInterval(4)))
        precondition(filling.isBlocked("clé-3", now: start.addingTimeInterval(4)))
        precondition(filling.blockedReason("clé-1", now: start.addingTimeInterval(4)) == .absent)

        // 5. Une clé jamais marquée n'est jamais bloquée.
        precondition(!bounded.isBlocked("inconnue", now: start))
        precondition(bounded.blockedReason("inconnue", now: start) == nil)

        print("Thumbnail failure ledger checks passed")
    }
}