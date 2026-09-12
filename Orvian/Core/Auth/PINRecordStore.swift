import Foundation

/// Une empreinte de PIN n'est pas un jeton réutilisable : contrairement au
/// token cloud, sa dérivation salée peut rester locale si le Keychain manque
/// (LiveContainer). Une ancienne empreinte n'est retirée qu'après migration.
@MainActor
final class PINRecordStore {
    private let service = "com.orvian.app.applock"
    private let account = "lock-code"
    private let fallbackKey = "orvian.applock.fallback"
    private var cached: String?
    private let defaults: UserDefaults
    private let access: KeychainSupport.Access

    init(defaults: UserDefaults = .standard, access: KeychainSupport.Access = .system) {
        self.defaults = defaults
        self.access = access
    }

    func current() -> String? {
        if let cached { return cached }
        let secure = access.read(service, account)
        let fallback = defaults.string(forKey: fallbackKey)
        // Si une mise à jour Keychain a échoué, la dérivation locale récente
        // doit primer sur l'ancienne valeur Keychain.
        let value = fallback ?? secure
        cached = value
        return value
    }

    func save(_ record: String) -> Bool {
        // Ne jamais introduire de nouvelle empreinte SHA-256 rapide, ni de
        // code en clair dans le repli. make() a produit le format versionné.
        guard record.hasPrefix(PINCredential.prefix) else { return false }
        if access.write(record, service, account) {
            defaults.removeObject(forKey: fallbackKey)
        } else {
            defaults.set(record, forKey: fallbackKey)
        }
        cached = record
        return true
    }

    func clear() {
        KeychainSupport.delete(service: service, account: account, fallbackKey: fallbackKey)
        defaults.removeObject(forKey: fallbackKey)
        cached = nil
    }
}
