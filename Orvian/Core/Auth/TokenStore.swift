import Foundation
import Security

/// Stockage du token API.
///
/// Le token n'est jamais écrit dans `UserDefaults`. Quand le Keychain n'est
/// pas disponible (certains conteneurs tiers), il reste uniquement en mémoire
/// pour la session en cours.
enum TokenStore {
    private static let keychainService = "com.orvian.app.api-token"
    /// Ancienne clé utilisée avant que le repli persistant soit supprimé.
    /// Elle est purgée pour éviter de conserver un token déjà exposé.
    private static let legacyDefaultsKey = "orvian.api-token.fallback"
    private static let lock = NSLock()
    private static var cached: String?
    private static var didPurgeLegacyFallback = false

    static func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        purgeLegacyFallback()
        if let cached { return cached }
        guard let token = readKeychain() else { return nil }
        cached = token
        return token
    }

    /// Renvoie `true` si le token survit à un redémarrage de l'app. Un échec
    /// Keychain garde le token seulement en mémoire : utile pour la session,
    /// sans l'exposer dans le conteneur de l'application.
    @discardableResult
    static func save(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        cached = trimmed
        purgeLegacyFallback()
        return writeKeychain(trimmed)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        deleteKeychain()
        purgeLegacyFallback()
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
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func deleteKeychain() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    private static func purgeLegacyFallback() {
        guard !didPurgeLegacyFallback else { return }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        didPurgeLegacyFallback = true
    }
}
