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

    var onUnauthorized: (() -> Void)?

    private let service: KDriveService
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let accountId = "orvian.account-id"
        static let driveId = "orvian.drive-id"
    }

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
        phase = .bootstrapping
        do {
            try await loadDrives(preferredDriveId: defaults.object(forKey: Keys.driveId) as? Int)
            phase = .signedIn
        } catch {
            if error is APIError, (error as? APIError)?.isUnauthorized == true {
                TokenStore.clear()
                phase = .signedOut
            } else {
                phase = .error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Connexion avec un token collé par l'utilisateur.
    func signIn(token: String) async throws {
        TokenStore.save(token)
        phase = .bootstrapping
        do {
            try await loadDrives(preferredDriveId: nil)
            guard selectedDrive != nil else {
                throw APIError.invalidResponse
            }
            phase = .signedIn
        } catch {
            TokenStore.clear()
            phase = .signedOut
            throw error
        }
    }

    func signOut() {
        TokenStore.clear()
        defaults.removeObject(forKey: Keys.accountId)
        defaults.removeObject(forKey: Keys.driveId)
        drives = []
        selectedDrive = nil
        accountId = nil
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
