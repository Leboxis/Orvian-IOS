import Foundation
import Security
import CryptoKit

/// Stockage du code de verrouillage : seule l'empreinte SHA-256 du code est
/// conservée (Keychain, repli UserDefaults), jamais le code lui-même.
enum AppLockStore {
    private static let keychainService = "com.orvian.app.applock"
    private static let keychainAccount = "lock-code"
    private static let defaultsKey = "orvian.applock.fallback"
    private static let lock = NSLock()
    private static var cachedHash: String?

    /// Vrai si un code de verrouillage est configuré sur cet appareil.
    static var isConfigured: Bool { currentHash() != nil }

    static func verify(_ code: String) -> Bool {
        guard let hash = currentHash() else { return false }
        return hash == TokenStore.fingerprint(of: code)
    }

    static func save(_ code: String) {
        let hash = TokenStore.fingerprint(of: code)
        lock.lock()
        defer { lock.unlock() }
        cachedHash = hash
        if writeKeychain(hash) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(hash, forKey: defaultsKey)
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        cachedHash = nil
        deleteKeychain()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func currentHash() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedHash { return cachedHash }
        guard let hash = readKeychain() ?? readDefaults() else { return nil }
        cachedHash = hash
        return hash
    }

    // MARK: - Keychain (même modèle que TokenStore, repli pour LiveContainer)

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func readKeychain() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ hash: String) -> Bool {
        let data = Data(hash.utf8)
        var query = keychainQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func deleteKeychain() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    private static func readDefaults() -> String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }
}
