import Foundation
import Security
import CryptoKit

/// Stockage du token API.
///
/// Keychain en priorité ; repli sur UserDefaults si le Keychain est
/// indisponible (cas rencontré dans certains conteneurs tiers comme
/// LiveContainer, où l'entitlement keychain manque).
enum TokenStore {
    private static let keychainService = "com.orvian.app.api-token"
    private static let defaultsKey = "orvian.api-token.fallback"
    private static let lock = NSLock()
    private static var cached: String?

    static func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let token = readKeychain() ?? readDefaults() else { return nil }
        cached = token
        return token
    }

    static func save(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        cached = trimmed
        if writeKeychain(trimmed) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        deleteKeychain()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Empreinte non réversible utilisée pour rattacher une réponse 401 au
    /// token qui a réellement signé la requête. Une réponse tardive d'une
    /// ancienne session ne peut ainsi pas déconnecter un nouveau compte.
    static func credentialFingerprint() -> String? {
        guard let token = current() else { return nil }
        return fingerprint(of: token)
    }

    static func fingerprint(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Keychain

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "orvian",
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

    private static func writeKeychain(_ token: String) -> Bool {
        let data = Data(token.utf8)
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

    // MARK: - Repli UserDefaults

    private static func readDefaults() -> String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }
}
