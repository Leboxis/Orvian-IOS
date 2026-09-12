import Foundation
import Security

/// Accès bas niveau au Keychain, avec repli `UserDefaults` si le Keychain est
/// indisponible (cas rencontré dans certains conteneurs tiers comme
/// LiveContainer, où l'entitlement keychain manque).
///
/// Un seul emplacement pour le motif « generic password avec repli », utilisé
/// auparavant indépendamment par `TokenStore` et `AppLockStore`.
enum KeychainSupport {
    /// Lit une valeur : Keychain en priorité, puis repli `UserDefaults`.
    static func read(service: String, account: String, fallbackKey: String) -> String? {
        readKeychain(service: service, account: account)
            ?? UserDefaults.standard.string(forKey: fallbackKey)
    }

    /// Écrit une valeur. Renvoie `true` si le Keychain a accepté l'écriture ;
    /// sinon la valeur est conservée dans `UserDefaults` et `false` est
    /// renvoyé. Dans tous les cas, le repli est nettoyé quand le Keychain est
    /// utilisé.
    @discardableResult
    static func write(_ value: String, service: String, account: String, fallbackKey: String) -> Bool {
        if writeKeychain(value, service: service, account: account) {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            return true
        }
        UserDefaults.standard.set(value, forKey: fallbackKey)
        return false
    }

    /// Supprime la valeur du Keychain et de son repli `UserDefaults`.
    static func delete(service: String, account: String, fallbackKey: String) {
        deleteKeychain(service: service, account: account)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }

    // MARK: - Keychain

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain(service: String, account: String) -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        var query = query(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func deleteKeychain(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}

/// Valeur secrète conservée en mémoire après sa première lecture, avec un
/// accès protégé par verrou. Deux implémentations l'utilisaient séparément
/// (`TokenStore`, `AppLockStore`) : ce type centralise le motif.
final class CachedSecureValue: @unchecked Sendable {
    private let service: String
    private let account: String
    private let fallbackKey: String
    private let lock = NSLock()
    private var cached: String?

    init(service: String, account: String, fallbackKey: String) {
        self.service = service
        self.account = account
        self.fallbackKey = fallbackKey
    }

    /// Valeur courante, lue au plus une fois (ensuite servie depuis la mémoire).
    func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let value = KeychainSupport.read(service: service, account: account, fallbackKey: fallbackKey) else {
            return nil
        }
        cached = value
        return value
    }

    func save(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        cached = value
        KeychainSupport.write(value, service: service, account: account, fallbackKey: fallbackKey)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        KeychainSupport.delete(service: service, account: account, fallbackKey: fallbackKey)
    }
}
