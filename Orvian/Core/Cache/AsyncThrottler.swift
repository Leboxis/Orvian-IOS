import Foundation

/// Régulateur de concurrence purement asynchrone (aucun thread bloqué).
/// Partagé par les pipelines de médias (miniatures, images haute résolution).
final class AsyncThrottler: @unchecked Sendable {
    private let maxConcurrent: Int
    private var activeCount = 0
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private let lock = NSLock()

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if activeCount < maxConcurrent && waiters.isEmpty {
                    activeCount += 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                order.append(id)
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            cancel(id)
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        if continuation != nil {
            order.removeAll { $0 == id }
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func release() {
        lock.lock()
        while !order.isEmpty {
            let id = order.removeFirst()
            if let next = waiters.removeValue(forKey: id) {
                lock.unlock()
                next.resume()
                return
            }
        }
        activeCount = max(0, activeCount - 1)
        lock.unlock()
    }
}
