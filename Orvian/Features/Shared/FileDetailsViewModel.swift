import Foundation
import Observation

@MainActor @Observable
final class FileDetailsViewModel {
    private(set) var file: DriveFile?
    private(set) var categories: [Category] = []
    private(set) var isLoading = false
    private(set) var infoError: String?
    private(set) var tagsError: String?
    private var generation = 0
    private let service = KDriveService()

    func load(file: DriveFile, driveId: Int, isTrashed: Bool) async {
        generation += 1
        let request = generation
        let credential = TokenStore.credentialFingerprint()
        self.file = file
        categories = []
        infoError = nil
        tagsError = nil
        isLoading = true
        defer { if generation == request { isLoading = false } }
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == request && credential == TokenStore.credentialFingerprint()
        }
        guard credential != nil else { tagsError = "Tags indisponibles hors connexion au compte."; return }
        guard !isTrashed else { return }
        if file.path == nil || file.categories == nil {
            do {
                let fresh = try await service.fileInfo(driveId: driveId, fileId: file.id)
                guard isCurrent() else { return }
                self.file = fresh
            } catch {
                guard isCurrent() else { return }
                infoError = "Informations incomplètes : \(error.localizedDescription)"
            }
        }
        do {
            try await CategoryLibrary.shared.requireLoaded(for: driveId)
            guard isCurrent() else { return }
            let library = CategoryLibrary.shared.categories(for: driveId)
            if let membership = self.file?.categories {
                categories = membership.compactMap { library[$0.categoryId] }
            } else {
                tagsError = "Impossible de vérifier les tags de cet élément."
            }
        } catch {
            guard isCurrent() else { return }
            tagsError = "Tags indisponibles : \(error.localizedDescription)"
        }
    }
}
