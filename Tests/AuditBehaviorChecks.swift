import Foundation

actor RestoreServer {
    var destinations: [Int] = []
    var failure: Error?
    var parentMissing = false
    var changeCredential = false
    func configure(_ error: Error?, parentMissing: Bool = false, changeCredential: Bool = false) {
        destinations = []
        failure = error
        self.parentMissing = parentMissing
        self.changeCredential = changeCredential
    }
    func restore(_ destination: Int) throws {
        destinations.append(destination)
        if destination != 1, let failure {
            if changeCredential { TokenStore.value = "account-b" }
            throw failure
        }
    }
    func parent() throws -> Int {
        if parentMissing { throw APIError.http(status: 404, code: nil, description: nil) }
        return 10
    }
}

struct KDriveService {
    let server: RestoreServer
    func restore(driveId: Int, fileId: Int, destinationDirectoryId: Int, credentialFingerprint: String?) async throws {
        try await server.restore(destinationDirectoryId)
    }
    func fileInfo(driveId: Int, fileId: Int) async throws -> Int { try await server.parent() }
}
enum TokenStore {
    static var value = "account-a"
    static func credentialFingerprint() -> String? { value }
}

actor WorkGate {
    var active = 0
    var maximum = 0
    var started = 0
    var waiting: [CheckedContinuation<Void, Never>] = []
    func work() async {
        active += 1
        started += 1
        maximum = max(maximum, active)
        await withCheckedContinuation { waiting.append($0) }
        active -= 1
    }
    func releaseAll() {
        let current = waiting
        waiting = []
        current.forEach { $0.resume() }
    }
}

@main struct AuditBehaviorChecks {
    static func main() async throws {
        let server = RestoreServer()
        let service = KDriveService(server: server)
        let errors: [Error] = [
            APIError.http(status: 403, code: nil, description: nil),
            APIError.http(status: 429, code: nil, description: nil),
            APIError.http(status: 500, code: nil, description: nil),
            APIError.network(URLError(.timedOut)), CancellationError()
        ]
        for error in errors {
            await server.configure(error, parentMissing: true)
            do {
                _ = try await service.restoreToOriginalOrRoot(driveId: 7, fileId: 2,
                    originalDirectoryId: 10, credentialFingerprint: "account-a")
                preconditionFailure("An unrelated error must propagate")
            } catch {}
            let calls = await server.destinations
            precondition(calls == [10], "No retry after network, permissions, rate limit or cancellation")
        }
        let missing = APIError.http(status: 404, code: nil, description: nil)
        await server.configure(missing)
        do {
            _ = try await service.restoreToOriginalOrRoot(driveId: 7, fileId: 2,
                originalDirectoryId: 10, credentialFingerprint: "account-a")
            preconditionFailure("A missing file with an existing parent must not be retried")
        } catch {}
        let noFallback = await server.destinations
        precondition(noFallback == [10])
        await server.configure(missing, parentMissing: true)
        let root = try await service.restoreToOriginalOrRoot(driveId: 7, fileId: 2,
            originalDirectoryId: 10, credentialFingerprint: "account-a")
        let fallback = await server.destinations
        precondition(root == 1 && fallback == [10, 1])
        await server.configure(missing, parentMissing: true, changeCredential: true)
        do {
            _ = try await service.restoreToOriginalOrRoot(driveId: 7, fileId: 2,
                originalDirectoryId: 10, credentialFingerprint: "account-a")
            preconditionFailure("A new credential must stop the restore")
        } catch is CancellationError {}
        let oldSession = await server.destinations
        precondition(oldSession == [10])

        let permits = AsyncPermitPool(capacity: 4)
        let gate = WorkGate()
        func startWork() -> Task<Void, Error> {
            Task {
                try await permits.acquire()
                await gate.work()
                await permits.release()
            }
        }
        let firstBatch = (0..<4).map { _ in startWork() }
        while await gate.started < 4 { await Task.yield() }
        let cancelledRetry = Task { try await permits.acquire() }
        cancelledRetry.cancel()
        do {
            try await cancelledRetry.value
            preconditionFailure("Cancelled waiting retry must exit without a permit")
        } catch is CancellationError {}
        let secondBatch = (0..<8).map { _ in startWork() }
        for _ in 0..<50 { await Task.yield() }
        let initialMaximum = await gate.maximum
        precondition(initialMaximum == 4)
        while await gate.started < 12 {
            await gate.releaseAll()
            await Task.yield()
        }
        await gate.releaseAll()
        for task in firstBatch + secondBatch { try await task.value }
        let maximum = await gate.maximum
        precondition(maximum <= 4, "All batches and retries must share one budget")
        // A cancelled waiter must neither leak nor inflate the permit count.
        for _ in 0..<4 { try await permits.acquire() }
        for _ in 0..<4 { await permits.release() }
        print("Restore error policy, session boundary and shared upload budget checks passed")
    }
}
