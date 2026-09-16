import Foundation
import Security

/// Secrets persistés exclusivement dans le Keychain. Les anciens replis sont
/// migrés puis effacés ; aucun nouveau secret n'est écrit dans UserDefaults.
enum KeychainSupport {
    struct Access {
        var read: (String, String) -> String?
        var write: (String, String, String) -> Bool
        static let system = Access(read: KeychainSupport.readKeychain, write: KeychainSupport.writeKeychain)
    }
    /// Un ancien secret reste utilisable en mémoire pour cette session si sa
    /// migration échoue, mais sa copie non sécurisée est toujours supprimée.
    static func read(service: String, account: String, fallbackKey: String,
                     defaults: UserDefaults = .standard, access: Access = .system) -> String? {
        if let value = access.read(service, account) {
            defaults.removeObject(forKey: fallbackKey)
            return value
        }
        guard let legacy = defaults.string(forKey: fallbackKey) else { return nil }
        _ = write(legacy, service: service, account: account, fallbackKey: fallbackKey, defaults: defaults, access: access)
        return legacy
    }

    /// Renvoie false si le secret ne peut pas être persisté en sécurité.
    @discardableResult
    static func write(_ value: String, service: String, account: String, fallbackKey: String,
                      defaults: UserDefaults = .standard, access: Access = .system) -> Bool {
        let saved = access.write(value, service, account)
        defaults.removeObject(forKey: fallbackKey)
        return saved
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
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
/// Le jeton peut rester en mémoire si sa persistance sécurisée échoue.
final class CachedSecureValue: @unchecked Sendable {
    private let service: String
    private let account: String
    private let fallbackKey: String
    private let lock = NSLock()
    private var cached: String?
    private var hasLoaded = false

    init(service: String, account: String, fallbackKey: String) {
        self.service = service
        self.account = account
        self.fallbackKey = fallbackKey
    }

    /// Valeur courante, lue au plus une fois (ensuite servie depuis la mémoire).
    func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return cached
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        cached = KeychainSupport.read(service: service, account: account, fallbackKey: fallbackKey)
        hasLoaded = true
    }

    /// Lecture et vérification de persistance sous une seule section critique :
    /// clear() ne peut pas s'intercaler puis être annulé par une ancienne valeur.
    func prepare() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let cached else { return true }
        return KeychainSupport.write(cached, service: service, account: account, fallbackKey: fallbackKey)
    }

    @discardableResult
    func save(_ value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let saved = KeychainSupport.write(value, service: service, account: account, fallbackKey: fallbackKey)
        cached = value
        hasLoaded = true
        return saved
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        hasLoaded = true
        KeychainSupport.delete(service: service, account: account, fallbackKey: fallbackKey)
    }
}
