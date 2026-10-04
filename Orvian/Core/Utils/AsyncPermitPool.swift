import Foundation

/// One shared budget across batches and retries. Cancelled queued work leaves
/// immediately and never starts importing a file or using another session.
actor AsyncPermitPool {
    private let capacity: Int
    private var active = 0
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < capacity {
                active += 1
                return
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                order.append(id)
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Cancellation may race with a released permit. Give that permit back.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        active -= 1
        precondition(active >= 0)
    }

    private func cancel(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}
