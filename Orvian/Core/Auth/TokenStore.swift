import Foundation
import CryptoKit

/// Stockage du token API.
///
/// Keychain en priorité ; repli sur UserDefaults si le Keychain est
/// indisponible (cas rencontré dans certains conteneurs tiers comme
/// LiveContainer, où l'entitlement keychain manque).
enum TokenStore {
    private static let store = CachedSecureValue(
        service: "com.orvian.app.api-token",
        account: "orvian",
        fallbackKey: "orvian.api-token.fallback"
    )

    static func current() -> String? {
        store.current()
    }

    static func save(_ token: String) {
        store.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func clear() {
        store.clear()
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
}
