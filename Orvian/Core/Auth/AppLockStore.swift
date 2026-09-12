import Foundation

/// Stockage du code de verrouillage : seule l'empreinte SHA-256 du code est
/// conservée (Keychain, repli UserDefaults), jamais le code lui-même.
enum AppLockStore {
    private static let store = CachedSecureValue(
        service: "com.orvian.app.applock",
        account: "lock-code",
        fallbackKey: "orvian.applock.fallback"
    )

    /// Vrai si un code de verrouillage est configuré sur cet appareil.
    static var isConfigured: Bool { currentHash() != nil }

    static func verify(_ code: String) -> Bool {
        guard let hash = currentHash() else { return false }
        return hash == TokenStore.fingerprint(of: code)
    }

    static func save(_ code: String) {
        store.save(TokenStore.fingerprint(of: code))
    }

    static func clear() {
        store.clear()
    }

    private static func currentHash() -> String? {
        store.current()
    }
}
