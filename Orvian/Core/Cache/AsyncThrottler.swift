import Foundation

/// Régulateur de concurrence purement asynchrone (aucun thread bloqué).
/// Partagé par les pipelines de médias (miniatures, images haute résolution).
final class AsyncThrottler: @unchecked Sendable {
    private let maxConcurrent: Int
    private var activeCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        // Décision et inscription sous une seule section critique : sinon un
        // release() survenant entre le test du compteur et l'inscription dans
        // la file voyait une file vide et décrémentait le compteur au lieu de
        // transférer le permis — le waiter dormait alors sans raison.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if activeCount < maxConcurrent && continuations.isEmpty {
                activeCount += 1
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
        // Un waiter réveillé alors que sa tâche a été annulée entre
        // immédiatement dans l'opération, dont la garde `Task.isCancelled`
        // rend le permis sans délai via le `defer` de `withPermit` : aucun
        // permis n'est consommé par un waiter obsolète.
    }

    private func release() {
        lock.lock()
        if !continuations.isEmpty {
            let next = continuations.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            activeCount = max(0, activeCount - 1)
            lock.unlock()
        }
    }
}
