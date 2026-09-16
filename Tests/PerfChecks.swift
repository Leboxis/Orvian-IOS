// Appended to Perf.swift by check_ios_regressions.py so these checks can
// exercise the actual private snapshot/publication boundary deterministically.
extension Perf {
    @MainActor
    static func checkPublicationRaces() async {
        let perf = Perf()
        var publications = 0
        let observation = perf.$summary.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel(); perf.reset() }

        for index in 0..<30 {
            perf.record(method: "GET", path: index < 20 ? "/thumbnail" : "/files",
                        status: 200, durationMs: index < 20 ? 500 : 25, bytes: 1)
        }
        await perf.publishTask?.value
        precondition(publications == 1, "A burst must publish only once")
        precondition(perf.totalRequests == 30 && perf.thumbnailRequests == 20)
        precondition(perf.entries.count == 10 && perf.averageMs == 25)

        // Pause after snapshot capture, exactly where reset used to race.
        perf.record(method: "GET", path: "/old", status: 200, durationMs: 1, bytes: 1)
        perf.publishTask?.cancel()
        let oldGeneration = perf.publishGeneration
        let stale = perf.makeSummary(generation: oldGeneration)!
        perf.reset()
        perf.publish(stale, generation: oldGeneration)
        precondition(perf.totalRequests == 0 && perf.entries.isEmpty,
                     "A captured snapshot must not undo reset")

        // A stale completion must also leave the new publication slot intact.
        perf.record(method: "GET", path: "/new", status: 200, durationMs: 1, bytes: 1)
        perf.publish(stale, generation: oldGeneration)
        precondition(perf.publishTask != nil)
        await perf.publishTask?.value
        precondition(perf.totalRequests == 1 && perf.entries.first?.path == "/new")

        // A final request arriving during publication must not remain hidden
        // forever just because no further network traffic follows it.
        perf.reset()
        perf.record(method: "GET", path: "/first", status: 200, durationMs: 1, bytes: 1)
        perf.publishTask?.cancel()
        let generation = perf.publishGeneration
        let snapshot = perf.makeSummary(generation: generation)!
        perf.record(method: "GET", path: "/last", status: 200, durationMs: 1, bytes: 1)
        perf.publish(snapshot, generation: generation)
        await perf.publishTask?.value
        precondition(perf.totalRequests == 2 && perf.entries.count == 2)

        perf.reset()
        for _ in 0..<450 {
            perf.record(method: "GET", path: "/files", status: 200, durationMs: 1, bytes: 1)
        }
        await perf.publishTask?.value
        precondition(perf.totalRequests == 450 && perf.entries.count == 400)
    }
}

@main
struct PerfChecks {
    static func main() async {
        await Perf.checkPublicationRaces()
        print("Perf coalescing, reset race, trailing request and capacity checks passed")
    }
}
