import Foundation
import Observation

/// Session applicative : token, compte, drives, drive sélectionné.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case signedOut
        case bootstrapping
        case signedIn
        case error(String)
    }

    private(set) var phase: Phase = .signedOut
    private(set) var drives: [Drive] = []
    private(set) var accountId: Int?
    private(set) var selectedDrive: Drive?
    private(set) var signedOutMessage: String?

    private let service: KDriveService
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let accountId = "orvian.account-id"
        static let driveId = "orvian.drive-id"
    }

    private static let expiredSessionMessage =
        "Votre token a expiré ou a été révoqué. Connectez-vous avec un token valide."

    init(service: KDriveService = KDriveService()) {
        self.service = service
    }

    var isSignedIn: Bool { phase == .signedIn && selectedDrive != nil }

    // MARK: - Cycle de vie

    /// Au lancement : si un token existe, retrouve compte + drive sélectionné.
    func bootstrap() async {
        guard TokenStore.current() != nil else {
            phase = .signedOut
            return
        }
        signedOutMessage = nil
        phase = .bootstrapping
        do {
            try await loadDrives(preferredDriveId: defaults.object(forKey: Keys.driveId) as? Int)
            phase = .signedIn
        } catch {
            if error is APIError, (error as? APIError)?.isUnauthorized == true {
                clearSession(message: Self.expiredSessionMessage)
            } else {
                phase = .error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Connexion avec un token collé par l'utilisateur.
    func signIn(token: String) async throws {
        signedOutMessage = nil
        DirectoryListStore.shared.clear()
        CategoryLibrary.shared.clear()
        TokenStore.save(token)
        phase = .bootstrapping
        do {
            try await loadDrives(preferredDriveId: nil)
            guard selectedDrive != nil else {
                throw APIError.invalidResponse
            }
            phase = .signedIn
        } catch {
            clearSession(message: nil)
            throw error
        }
    }

    func signOut() {
        clearSession(message: nil)
    }

    /// Ignore un 401 tardif provenant d'un ancien token, puis ferme
    /// immédiatement la session réellement expirée.
    func handleUnauthorized(credentialFingerprint: String?) {
        guard let credentialFingerprint,
              credentialFingerprint == TokenStore.credentialFingerprint()
        else { return }
        clearSession(message: Self.expiredSessionMessage)
    }

    private func clearSession(message: String?) {
        // Annuler avant d'effacer le token afin que les URLSession actives
        // cessent d'envoyer des octets avec les anciennes autorisations.
        UploadManager.shared.cancelAllAndClear()
        DirectoryListStore.shared.clear()
        CategoryLibrary.shared.clear()
        TokenStore.clear()
        defaults.removeObject(forKey: Keys.accountId)
        defaults.removeObject(forKey: Keys.driveId)
        drives = []
        selectedDrive = nil
        accountId = nil
        signedOutMessage = message
        phase = .signedOut
    }

    func selectDrive(_ drive: Drive) {
        selectedDrive = drive
        defaults.set(drive.id, forKey: Keys.driveId)
    }

    /// Force le rechargement des drives (onglet Plus).
    func reloadDrives() async throws {
        try await loadDrives(preferredDriveId: selectedDrive?.id)
    }

    // MARK: - Internes

    private func loadDrives(preferredDriveId: Int?) async throws {
        if let stored = defaults.object(forKey: Keys.accountId) as? Int,
           let list = try? await service.drives(accountId: stored), !list.isEmpty {
            apply(list, accountId: stored, preferredDriveId: preferredDriveId)
            return
        }

        let (accountId, list) = try await service.discoverDrives()
        defaults.set(accountId, forKey: Keys.accountId)
        apply(list, accountId: accountId, preferredDriveId: preferredDriveId)
    }

    private func apply(_ list: [Drive], accountId: Int, preferredDriveId: Int?) {
        drives = list
        self.accountId = accountId
        if let preferredDriveId, let match = list.first(where: { $0.id == preferredDriveId }) {
            selectedDrive = match
        } else {
            selectedDrive = list.first
        }
        if let selectedDrive {
            defaults.set(selectedDrive.id, forKey: Keys.driveId)
        }
    }
}

