import Foundation

extension SharedRequests {
    func subscriberCount(for key: Key) -> Int { requests[key]?.waiters.count ?? 0 }
}

actor TestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@main struct ConcurrencyChecks {
    static func main() async throws {
        let shared = SharedRequests<String, Int>()
        let gate = TestGate()
        let first = Task { try await shared.value(for: "same") { await gate.wait(); return 42 } }
        while await shared.subscriberCount(for: "same") != 1 { await Task.yield() }
        let second = Task { try await shared.value(for: "same") { preconditionFailure("Duplicate request") } }
        while await shared.subscriberCount(for: "same") != 2 { await Task.yield() }
        first.cancel()
        do { _ = try await first.value; preconditionFailure("Cancelled waiter must return") }
        catch is CancellationError {}
        let remaining = await shared.subscriberCount(for: "same")
        precondition(remaining == 1, "Cancellation must preserve the other screen")
        await gate.release()
        let value = try await second.value
        precondition(value == 42)

        let stopped = TestGate()
        let last = Task {
            try await shared.value(for: "last") {
                do { try await Task.sleep(for: .seconds(30)); return 0 }
                catch { await stopped.release(); throw error }
            }
        }
        while await shared.subscriberCount(for: "last") != 1 { await Task.yield() }
        last.cancel()
        do { _ = try await last.value; preconditionFailure("Last waiter must cancel") }
        catch is CancellationError {}
        await stopped.wait()
        let replacement = try await shared.value(for: "last") { 7 }
        precondition(replacement == 7)

        // Le troisième élément doit commencer alors que le premier reste
        // bloqué : garantit une fenêtre glissante, sans test chronométrique.
        let slow = TestGate()
        let results = await mapBounded([0, 1, 2, 3], concurrency: 2) { index in
            if index == 0 { await slow.wait() }
            if index == 2 { await slow.release() }
            return index
        }
        precondition(results == [0, 1, 2, 3], "Result order must remain stable")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = DiskDirectory(root: folder)
        let file = directory.url("thumbnail")
        precondition(directory.write(Data([1]), to: file))
        let oldEntry = directory.entries()[0]
        directory.purge()
        precondition(directory.write(Data([2]), to: file))
        precondition(directory.remove(oldEntry.url, expectedGeneration: oldEntry.generation) == nil)
        let newData = try Data(contentsOf: file)
        precondition(newData == Data([2]), "An old eviction must not delete a new thumbnail")

        let decoded = try await ResponseDecoder.decode([Int].self, from: Data("[1,2]".utf8))
        precondition(decoded == [1, 2])
        let hugeError = APIError.decoding(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test")),
                                         raw: Data(repeating: 32, count: 5 * 1024 * 1024))
        precondition(hugeError.errorDescription != nil)
        print("Concurrency, cancellation, purge generations and decoding checks passed")
    }
}
