import Foundation

extension KDriveService {
    /// A 404 on restoration alone cannot distinguish a missing file from a
    /// missing parent. Confirm the parent is absent before changing destination.
    func restoreToOriginalOrRoot(
        driveId: Int, fileId: Int, originalDirectoryId: Int,
        credentialFingerprint: String?
    ) async throws -> Int {
        func checkSession() throws {
            try Task.checkCancellation()
            guard let credentialFingerprint,
                  credentialFingerprint == TokenStore.credentialFingerprint() else {
                throw CancellationError()
            }
        }
        try checkSession()
        do {
            try await restore(driveId: driveId, fileId: fileId, destinationDirectoryId: originalDirectoryId, credentialFingerprint: credentialFingerprint)
            try checkSession()
            return originalDirectoryId
        } catch {
            try checkSession()
            guard originalDirectoryId != 1,
                  case APIError.http(status: 404, code: _, description: _) = error else { throw error }
            let restoreError = error
            do {
                _ = try await fileInfo(driveId: driveId, fileId: originalDirectoryId)
            } catch {
                try checkSession()
                guard case APIError.http(status: 404, code: _, description: _) = error else { throw restoreError }
                try await restore(driveId: driveId, fileId: fileId, destinationDirectoryId: 1, credentialFingerprint: credentialFingerprint)
                try checkSession()
                return 1
            }
            throw restoreError
        }
    }
}
