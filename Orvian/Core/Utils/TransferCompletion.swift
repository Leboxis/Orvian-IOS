import Foundation

/// Rendez-vous entre le délégué URLSession et son appelant. Une annulation
/// peut terminer la tâche avant l'installation de la continuation : conserver
/// alors son résultat. Le verrou garantit une seule reprise dans tous les cas.
final class TransferCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var installed = false
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        precondition(!installed, "A transfer can only be awaited once")
        installed = true
        let ready = result
        result = nil
        if ready == nil { self.continuation = continuation }
        lock.unlock()
        if let ready { continuation.resume(with: ready) }
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { self.result = result }
        lock.unlock()
        waiting?.resume(with: result)
        return true
    }
}
