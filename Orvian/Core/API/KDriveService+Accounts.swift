import Foundation

/// Comptes et drives : découverte et sélection.
extension KDriveService {
    func accounts() async throws -> [InfomaniakAccount] {
        try await api.get(DataResponse<[InfomaniakAccount]>.self, .accounts).data ?? []
    }

    func drives(accountId: Int) async throws -> [Drive] {
        try await api.get(DataResponse<[Drive]>.self, .drives(accountId: accountId)).data ?? []
    }

    /// Parcourt les comptes du token et renvoie le premier qui possède des
    /// drives (la plupart des tokens personnels n'ont qu'un compte actif).
    func discoverDrives() async throws -> (accountId: Int, drives: [Drive]) {
        let accounts = try await self.accounts()
        var lastError: Error = APIError.invalidResponse
        for account in accounts {
            do {
                let drives = try await self.drives(accountId: account.id)
                if !drives.isEmpty {
                    return (account.id, drives)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
