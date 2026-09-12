import Foundation

/// PIN dérivé hors du MainActor. Les essais sont partagés entre les écrans.
@MainActor
enum AppLockStore {
    private static let store = PINRecordStore()

    private static let configuredKey = "orvian.applock.configured"
    private static let attemptsKey = "orvian.applock.attempts"
    private static let deadlineKey = "orvian.applock.deadline"
    private static var isWorking = false

    static var isConfigured: Bool {
        // Ne pas ouvrir l'app si le Keychain devient inaccessible.
        if UserDefaults.standard.bool(forKey: configuredKey) { return true }
        guard store.current() != nil else { return false }
        UserDefaults.standard.set(true, forKey: configuredKey)
        return true
    }

    static var retryAfter: Int {
        max(0, Int(ceil(UserDefaults.standard.double(forKey: deadlineKey) - Date().timeIntervalSince1970)))
    }

    static func verify(_ code: String) async throws -> Bool {
        guard !isWorking else { throw LockError.busy }
        guard retryAfter == 0 else { throw LockError.blocked }
        guard let record = store.current() else { throw LockError.unavailable }
        isWorking = true
        defer { isWorking = false }
        // Compter avant le calcul pour qu'une fermeture ne supprime pas l'essai.
        let attempts = max(0, min(UserDefaults.standard.integer(forKey: attemptsKey), 19)) + 1
        UserDefaults.standard.set(attempts, forKey: attemptsKey)
        let delay = PINAttemptPolicy.delay(after: attempts)
        if delay > 0 {
            UserDefaults.standard.set(Date().timeIntervalSince1970 + delay, forKey: deadlineKey)
        }
        let matches = try await Task.detached(priority: .userInitiated) {
            try PINCredential.verify(code, record: record)
        }.value
        guard matches else { return false }
        if !record.hasPrefix(PINCredential.prefix) {
            let upgraded = try await Task.detached(priority: .userInitiated) {
                try PINCredential.make(code)
            }.value
            guard store.save(upgraded) else { throw LockError.unavailable }
        }
        resetAttempts()
        return true
    }

    static func save(_ code: String) async throws {
        guard !isWorking else { throw LockError.busy }
        isWorking = true
        defer { isWorking = false }
        let record = try await Task.detached(priority: .userInitiated) {
            try PINCredential.make(code)
        }.value
        guard store.save(record) else { throw LockError.unavailable }
        UserDefaults.standard.set(true, forKey: configuredKey)
        resetAttempts()
    }

    static func resetAttempts() {
        UserDefaults.standard.removeObject(forKey: attemptsKey)
        UserDefaults.standard.removeObject(forKey: deadlineKey)
    }

    static func clear() {
        store.clear()
        UserDefaults.standard.removeObject(forKey: configuredKey)
        resetAttempts()
    }

    enum LockError: LocalizedError {
        case unavailable, blocked, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Le stockage sécurisé est indisponible. Réessayez après avoir déverrouillé l’iPhone."
            case .blocked: return "Trop de tentatives. Patientez avant de réessayer."
            case .busy: return "Vérification en cours…"
            }
        }
    }
}
