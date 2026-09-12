import Foundation
import CryptoKit

/// Stockage du token API.
///
/// Keychain uniquement sur disque ; session en mémoire si indisponible.
enum TokenStore {
    private static let fingerprintLock = NSLock()
    private static var fingerprintCache: (token: String, hash: String)?
    private static let store = CachedSecureValue(
        service: "com.orvian.app.api-token",
        account: "orvian",
        fallbackKey: "orvian.api-token.fallback"
    )

    static func current() -> String? {
        store.current()
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        store.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func clear() {
        store.clear()
        fingerprintLock.lock()
        fingerprintCache = nil
        fingerprintLock.unlock()
    }

    /// Empreinte non réversible utilisée pour rattacher une réponse 401 au
    /// token qui a réellement signé la requête. Une réponse tardive d'une
    /// ancienne session ne peut ainsi pas déconnecter un nouveau compte.
    static func credentialFingerprint() -> String? {
        guard let token = current() else { return nil }
        fingerprintLock.lock()
        defer { fingerprintLock.unlock() }
        if let cached = fingerprintCache, cached.token == token { return cached.hash }
        let hash = fingerprint(of: token)
        fingerprintCache = (token, hash)
        return hash
    }

    static func fingerprint(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
