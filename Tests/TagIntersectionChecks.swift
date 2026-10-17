import Foundation

private struct TaggedItem: Sendable, Equatable {
    let id: Int
    var isDirectory = false
    var tags: Set<Int>?
}

private actor MembershipServer {
    var active = 0
    var maximum = 0
    var calls = 0
    var account = "a"
    func switchAccount() { account = "b" }
    func counts() -> (Int, Int) { (calls, maximum) }
    func resolve(_ file: TaggedItem) async throws -> TaggedItem {
        guard account == "a" else { throw CancellationError() }
        active += 1; calls += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        guard account == "a" else { throw CancellationError() }
        if file.id == -1 { throw URLError(.notConnectedToInternet) }
        if file.id == -2 { return file }
        var resolved = file; resolved.tags = [1, 3]
        return resolved
    }
}

@main struct TagIntersectionChecks {
    static func main() async throws {
        let selection = TagIntersection([3, 1, 3])
        assert(selection.ids == [1, 3])
        assert(selection.matches([1, 2, 3]))
        assert(!selection.matches([1]))
        assert(!TagIntersection([]).matches([1, 3]))
        var state = TagIntersectionState()
        state.toggle(1); state.toggle(3)
        assert(state.isEditing && state.selectedIDs == [1, 3], "Checkmarks update the live query immediately")
        state.finish()
        assert(!state.isEditing && state.selectedIDs == [1, 3])
        state.clear()
        assert(state.selectedIDs.isEmpty)
        let endpoint = Endpoint.intersectionFiles(driveId: 42, selection: selection, cursor: "next")
        assert(endpoint.query.first { $0.name == "category" }?.value == "1")
        assert(endpoint.query.first { $0.name == "cursor" }?.value == "next")
        let server = MembershipServer()
        let membership: @Sendable (TaggedItem) -> Set<Int>? = { $0.tags }
        let resolve: @Sendable (TaggedItem) async throws -> TaggedItem = { try await server.resolve($0) }
        let known = [TaggedItem(id: 1, tags: [1, 3]), TaggedItem(id: 2, tags: [1]),
                     TaggedItem(id: 3, isDirectory: true, tags: [1, 3]),
                     TaggedItem(id: 4, tags: [])]
        let empty = try await TagIntersection([]).filterPage(known, membership: membership, resolve: resolve)
        assert(empty.isEmpty)
        let single = try await TagIntersection([1]).filterPage(known, membership: membership, resolve: resolve)
        assert(single.map(\.id) == [1, 2, 3])
        let matching = try await selection.filterPage(known, membership: membership, resolve: resolve)
        assert(matching.map(\.id) == [1, 3], "Directories match only their own tags; children don't inherit membership")
        let knownCounts = await server.counts()
        assert(knownCounts.0 == 0, "Known memberships must not launch per-row requests")
        let missing = (10..<22).map { TaggedItem(id: $0) }
        let completed = try await selection.filterPage(missing, membership: membership, resolve: resolve)
        assert(completed.map(\.id) == Array(10..<22), "Concurrent resolution preserves page ordering")
        let counts = await server.counts()
        assert(counts.0 == 12 && counts.1 <= 4)
        // A first filtered page can be empty while later pages contain results.
        let firstPage = try await selection.filterPage([known[1]], membership: membership, resolve: resolve)
        let nextPage = try await selection.filterPage([known[2]], membership: membership, resolve: resolve)
        assert(firstPage.isEmpty && nextPage.map(\.id) == [3])
        do {
            _ = try await selection.filterPage([TaggedItem(id: -1)], membership: membership, resolve: resolve)
            fatalError("A metadata network error must not become an empty result")
        } catch is URLError {}
        do {
            _ = try await selection.filterPage([TaggedItem(id: -2)], membership: membership, resolve: resolve)
            fatalError("A missing membership must remain an error")
        } catch is TagIntersectionError {}
        let cancellationServer = MembershipServer()
        let obsolete = Task {
            try await selection.filterPage(missing, membership: membership, resolve: { try await cancellationServer.resolve($0) })
        }
        while await cancellationServer.counts().0 == 0 { await Task.yield() }
        obsolete.cancel()
        do { _ = try await obsolete.value; fatalError("Cancelled query published results") }
        catch is CancellationError {}
        let accountServer = MembershipServer()
        let changed = Task {
            try await selection.filterPage(missing, membership: membership, resolve: { try await accountServer.resolve($0) })
        }
        while await accountServer.counts().0 == 0 { await Task.yield() }
        await accountServer.switchAccount()
        do { _ = try await changed.value; fatalError("Old-account query published results") }
        catch is CancellationError {}
        print("Live intersection, own membership, bounded resolution, empty pages, errors, cancellation and accounts passed")
    }
}