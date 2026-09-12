import Foundation

@main
struct SecurityChecks {
    @MainActor
    static func main() throws {
        // Vecteur PBKDF2-HMAC-SHA256 indépendant (password/salt, 1 itération).
        let vector = try PINCredential.derive("password", salt: Array("salt".utf8), rounds: 1)
        precondition(vector.map { String(format: "%02x", $0) }.joined() ==
                     "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let first = try PINCredential.make("0123")
        let second = try PINCredential.make("0123")
        precondition(first != second, "Every PIN must have a fresh random salt")
        let correct = try PINCredential.verify("0123", record: first)
        let wrong = try PINCredential.verify("0124", record: first)
        precondition(correct && !wrong)
        // SHA-256("1234") : migration d'une ancienne installation.
        let legacy = try PINCredential.verify("1234", record:
            "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4")
        precondition(legacy)
        do {
            _ = try PINCredential.verify("0123", record: "pbkdf2-sha256$999999999$bad$bad")
            preconditionFailure("Corrupt records must fail closed")
        } catch {}
        precondition(PINAttemptPolicy.delay(after: 4) == 0)
        precondition(PINAttemptPolicy.delay(after: 5) == 30)
        precondition(PINAttemptPolicy.delay(after: 6) == 60)
        precondition(PINAttemptPolicy.delay(after: 20) == 3_600)

        let suite = "orvian.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let denied = KeychainSupport.Access(read: { _, _ in nil }, write: { _, _, _ in false })
        let persisted = KeychainSupport.write("test-secret", service: "test", account: "test",
                                             fallbackKey: "legacy", defaults: defaults, access: denied)
        precondition(!persisted && defaults.string(forKey: "legacy") == nil,
                     "Keychain failure must never create a plaintext fallback")
        defaults.set("old-secret", forKey: "legacy")
        let transient = KeychainSupport.read(service: "test", account: "test", fallbackKey: "legacy",
                                            defaults: defaults, access: denied)
        precondition(transient == "old-secret" && defaults.string(forKey: "legacy") == nil)
        var migrated: String?
        let allowed = KeychainSupport.Access(read: { _, _ in nil }, write: { value, _, _ in
            migrated = value
            return true
        })
        defaults.set("migrate-me", forKey: "legacy")
        _ = KeychainSupport.read(service: "test", account: "test", fallbackKey: "legacy",
                                 defaults: defaults, access: allowed)
        precondition(migrated == "migrate-me" && defaults.string(forKey: "legacy") == nil)
        let pinStore = PINRecordStore(defaults: defaults, access: denied)
        precondition(!pinStore.save("0123"), "Plain PINs must never be persisted")
        defaults.set("legacy-hash", forKey: "orvian.applock.fallback")
        precondition(pinStore.current() == "legacy-hash", "Keep old locks readable until migration")
        precondition(pinStore.save(first))
        let reopened = PINRecordStore(defaults: defaults, access: denied)
        precondition(reopened.current() == first, "A derived PIN must survive relaunch without Keychain")
        precondition(defaults.string(forKey: "orvian.applock.fallback")!.hasPrefix(PINCredential.prefix))
        print("Security checks passed")
    }
}
