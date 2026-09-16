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

    private(set) var phase: Phase = .bootstrapping
    private(set) var drives: [Drive] = []
    private(set) var accountId: Int?
    private(set) var selectedDrive: Drive?
    private(set) var signedOutMessage: String?
    private(set) var usesTemporaryCredentials = false
    /// État d'interface qui survit au verrouillage de l'app (voir
    /// `MainTabShellState`). Créé au moment où un drive est sélectionné —
    /// jamais pendant un rendu — et jeté à la déconnexion.
    private(set) var mainShell: MainTabShellState?

    private var sessionGeneration = 0
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
        let generation = sessionGeneration
        let persisted = await TokenStore.prepare()
        guard !Task.isCancelled, generation == sessionGeneration else { return }
        guard TokenStore.current() != nil else {
            phase = .signedOut
            return
        }
        usesTemporaryCredentials = !persisted
        signedOutMessage = nil
        phase = .bootstrapping
        do {
            try await loadDrives(preferredDriveId: defaults.object(forKey: Keys.driveId) as? Int)
            guard generation == sessionGeneration else { return }
            phase = .signedIn
        } catch {
            guard generation == sessionGeneration, !(error is CancellationError) else { return }
            if error is APIError, (error as? APIError)?.isUnauthorized == true {
                clearSession(message: Self.expiredSessionMessage)
            } else {
                phase = .error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Connexion avec un token collé par l'utilisateur.
    func signIn(token: String) async throws {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        discardMediaLinks()
        signedOutMessage = nil
        DirectoryListStore.shared.clear()
        CategoryLibrary.shared.clear()
        usesTemporaryCredentials = !TokenStore.save(token)
        phase = .bootstrapping
        do {
            try await loadDrives(preferredDriveId: nil)
            guard selectedDrive != nil else {
                throw APIError.invalidResponse
            }
            phase = .signedIn
        } catch {
            guard generation == sessionGeneration else { throw CancellationError() }
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
        sessionGeneration &+= 1
        discardMediaLinks()
        // Annuler avant d'effacer le token afin que les URLSession actives
        // cessent d'envoyer des octets avec les anciennes autorisations.
        UploadManager.shared.cancelAllAndClear()
        DirectoryListStore.shared.clear()
        CategoryLibrary.shared.clear()
        TokenStore.clear()
        usesTemporaryCredentials = false
        defaults.removeObject(forKey: Keys.accountId)
        defaults.removeObject(forKey: Keys.driveId)
        drives = []
        selectedDrive = nil
        accountId = nil
        mainShell = nil
        signedOutMessage = message
        phase = .signedOut
    }

    private func discardMediaLinks() {
        RecentUploadsLoader.shared.clear()
        guard let credential = TokenStore.credentialFingerprint() else { return }
        Task { await MediaURLCache.shared.clear(credentialFingerprint: credential) }
    }

    func selectDrive(_ drive: Drive) {
        selectedDrive = drive
        refreshMainShell(for: drive)
        defaults.set(drive.id, forKey: Keys.driveId)
    }

    /// Un changement de drive reconstruit l'état d'interface, comme le
    /// `.id(drive.id)` de `RootView` reconstruit les onglets.
    private func refreshMainShell(for drive: Drive) {
        guard mainShell?.driveId != drive.id else { return }
        mainShell = MainTabShellState(driveId: drive.id)
    }

    /// Force le rechargement des drives (onglet Plus).
    func reloadDrives() async throws {
        try await loadDrives(preferredDriveId: selectedDrive?.id)
    }

    // MARK: - Internes

    private func loadDrives(preferredDriveId: Int?) async throws {
        let generation = sessionGeneration
        if let stored = defaults.object(forKey: Keys.accountId) as? Int,
           let list = try? await service.drives(accountId: stored), !list.isEmpty {
            guard !Task.isCancelled, generation == sessionGeneration else { throw CancellationError() }
            apply(list, accountId: stored, preferredDriveId: preferredDriveId)
            return
        }

        let (accountId, list) = try await service.discoverDrives()
        guard !Task.isCancelled, generation == sessionGeneration else { throw CancellationError() }
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
            refreshMainShell(for: selectedDrive)
            defaults.set(selectedDrive.id, forKey: Keys.driveId)
        }
    }
}
