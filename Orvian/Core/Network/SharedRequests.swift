import Foundation

/// Une requête par clé, un abonnement annulable par appelant. Seul le départ
/// du dernier abonné annule le réseau ; une ancienne réponse ne peut pas
/// terminer une nouvelle requête portant la même clé.
actor SharedRequests<Key: Hashable & Sendable, Value: Sendable> {
    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private var requests: [Key: Request] = [:]

    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var existing = requests[key] {
                    existing.waiters[waiterID] = continuation
                    requests[key] = existing
                    return
                }
                let requestID = UUID()
                let task = Task {
                    let result: Result<Value, Error>
                    do { result = .success(try await operation()) }
                    catch { result = .failure(error) }
                    finish(key, requestID: requestID, result: result)
                }
                requests[key] = Request(id: requestID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(key, waiterID: waiterID) }
        }
    }

    private func cancel(_ key: Key, waiterID: UUID) {
        guard let waiter = requests[key]?.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if requests[key]?.waiters.isEmpty == true {
            requests.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func finish(_ key: Key, requestID: UUID, result: Result<Value, Error>) {
        guard requests[key]?.id == requestID,
              let request = requests.removeValue(forKey: key) else { return }
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }
}
