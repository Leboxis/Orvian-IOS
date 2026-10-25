import Foundation

@main
struct AppLockChecks {
    @MainActor
    static func main() async throws {
        AppLockStore.clear()
        defer { AppLockStore.clear() }
        PINRecordStore.allowWrites = false
        do {
            try await AppLockStore.save("012345")
            preconditionFailure("A PIN must not be activated if its record cannot be saved")
        } catch is AppLockStore.LockError {}
        precondition(!AppLockStore.isConfigured)

        PINRecordStore.allowWrites = true
        try await AppLockStore.save("012345")
        precondition(AppLockStore.isConfigured && AppLockStore.codeLength == 6)
        let saved = PINRecordStore.value
        do {
            try await AppLockStore.save("0123")
            preconditionFailure("Four-digit codes can no longer be created")
        } catch PINCredential.CredentialError.invalidCode {}
        precondition(PINRecordStore.value == saved, "An invalid new code must leave the old lock intact")
        for _ in 0..<5 {
            let matches = try await AppLockStore.verify("999999")
            precondition(!matches)
        }
        precondition(AppLockStore.retryAfter > 0)
        precondition(UserDefaults.standard.integer(forKey: "orvian.applock.attempts") == 5)
        precondition(UserDefaults.standard.double(forKey: "orvian.applock.deadline") > Date().timeIntervalSince1970)
        do {
            _ = try await AppLockStore.verify("012345")
            preconditionFailure("Even a correct PIN must wait until the deadline")
        } catch AppLockStore.LockError.blocked {}
        AppLockStore.resetAttempts() // authentification biométrique réussie
        let matches = try await AppLockStore.verify("012345")
        precondition(matches && AppLockStore.retryAfter == 0)

        PINRecordStore.value = "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
        precondition(AppLockStore.codeLength == 4)
        let migrated = try await AppLockStore.verify("1234")
        precondition(migrated && PINRecordStore.value!.hasPrefix(PINCredential.prefix))
        precondition(AppLockStore.codeLength == 4, "Rehashing must preserve the existing code length")
        let reopened = try await AppLockStore.verify("1234")
        precondition(reopened)
        try await AppLockStore.save("001234")
        precondition(AppLockStore.codeLength == 6)
        let changed = try await AppLockStore.verify("001234")
        let obsolete = try await AppLockStore.verify("1234")
        precondition(changed && !obsolete, "Changing the code must switch verification to all six digits")
        PINRecordStore.value = nil // stockage momentanément inaccessible
        precondition(AppLockStore.isConfigured, "An inaccessible Keychain must not silently disable the lock")
        print("App lock migration and retry checks passed")
    }
}
