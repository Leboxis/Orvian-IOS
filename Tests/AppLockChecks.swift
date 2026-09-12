import Foundation

@main
struct AppLockChecks {
    @MainActor
    static func main() async throws {
        AppLockStore.clear()
        defer { AppLockStore.clear() }
        PINRecordStore.allowWrites = false
        do {
            try await AppLockStore.save("0123")
            preconditionFailure("A PIN must not be activated if its record cannot be saved")
        } catch is AppLockStore.LockError {}
        precondition(!AppLockStore.isConfigured)

        PINRecordStore.allowWrites = true
        try await AppLockStore.save("0123")
        precondition(AppLockStore.isConfigured)
        for _ in 0..<5 {
            let matches = try await AppLockStore.verify("9999")
            precondition(!matches)
        }
        precondition(AppLockStore.retryAfter > 0)
        precondition(UserDefaults.standard.integer(forKey: "orvian.applock.attempts") == 5)
        precondition(UserDefaults.standard.double(forKey: "orvian.applock.deadline") > Date().timeIntervalSince1970)
        do {
            _ = try await AppLockStore.verify("0123")
            preconditionFailure("Even a correct PIN must wait until the deadline")
        } catch AppLockStore.LockError.blocked {}
        AppLockStore.resetAttempts() // authentification biométrique réussie
        let matches = try await AppLockStore.verify("0123")
        precondition(matches && AppLockStore.retryAfter == 0)

        PINRecordStore.value = "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
        let migrated = try await AppLockStore.verify("1234")
        precondition(migrated && PINRecordStore.value!.hasPrefix(PINCredential.prefix))
        PINRecordStore.value = nil // stockage momentanément inaccessible
        precondition(AppLockStore.isConfigured, "An inaccessible Keychain must not silently disable the lock")
        print("App lock migration and retry checks passed")
    }
}
