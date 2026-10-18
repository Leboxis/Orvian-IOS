import Foundation
import Observation

@MainActor @Observable
final class FileDetailsViewModel {
    private(set) var file: DriveFile?
    private(set) var categories: [Category] = []
    private(set) var isLoading = false
    private(set) var isLoadingTags = false
    private(set) var infoError: String?
    private(set) var tagsError: String?
    private var generation = 0
    private let service = KDriveService()
    private struct Request: Equatable {
        let file: DriveFile
        let driveId: Int
        let isTrashed: Bool
        let credential: String?
    }
    private var request: Request?
    private var loadedAt: Date?

    /// The menu action can start this before its dismissal finishes. The
    /// inspector then joins the prepared model instead of repeating its GET.
    func loadIfNeeded(file: DriveFile, driveId: Int, isTrashed: Bool) async {
        let key = Request(file: file, driveId: driveId, isTrashed: isTrashed,
                          credential: TokenStore.credentialFingerprint())
        if request == key, isLoading || (loadedAt.map { Date().timeIntervalSince($0) < 60 } ?? false) {
            if !isLoading { resolveCategories(driveId: driveId) }
            return
        }
        await load(file: file, driveId: driveId, isTrashed: isTrashed)
    }

    func load(file: DriveFile, driveId: Int, isTrashed: Bool) async {
        generation += 1
        let request = generation
        let credential = TokenStore.credentialFingerprint()
        self.request = Request(file: file, driveId: driveId, isTrashed: isTrashed, credential: credential)
        loadedAt = nil
        self.file = file
        let knownCategories = CategoryLibrary.shared.categories(for: driveId)
        categories = (file.categories ?? []).compactMap { knownCategories[$0.categoryId] }
        infoError = nil
        tagsError = nil
        isLoading = true
        isLoadingTags = file.categories == nil
            || (!(file.categories?.isEmpty ?? true) && !CategoryLibrary.shared.hasLoaded(for: driveId))
        defer {
            if generation == request {
                isLoading = false
                isLoadingTags = false
                if Task.isCancelled { self.request = nil }
                else if infoError == nil && tagsError == nil { loadedAt = Date() }
            }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == request && credential == TokenStore.credentialFingerprint()
        }
        guard credential != nil else { tagsError = "Tags indisponibles hors connexion au compte."; return }
        guard !isTrashed else { return }
        // Independent requests: a missing path must not hold back known tags,
        // and a slow tag library must not hold back the file's facts.
        async let info: Void = loadInfo(file: file, driveId: driveId, isCurrent: isCurrent)
        async let tags: Void = loadCategories(driveId: driveId, isCurrent: isCurrent)
        _ = await (info, tags)
        guard isCurrent() else { return }
        if self.file?.categories == nil && tagsError == nil {
            tagsError = "Impossible de vérifier les tags de cet élément."
        }
    }

    private func loadInfo(file: DriveFile, driveId: Int, isCurrent: () -> Bool) async {
        guard file.path == nil || file.categories == nil else { return }
        do {
            let fresh = try await service.fileInfo(driveId: driveId, fileId: file.id)
            guard isCurrent() else { return }
            self.file = fresh
            resolveCategories(driveId: driveId)
        } catch {
            guard isCurrent() else { return }
            infoError = "Informations incomplètes : \(error.localizedDescription)"
        }
    }

    private func loadCategories(driveId: Int, isCurrent: () -> Bool) async {
        if file?.categories?.isEmpty == true && file?.path != nil { return }
        do {
            try await CategoryLibrary.shared.requireLoaded(for: driveId)
            guard isCurrent() else { return }
            resolveCategories(driveId: driveId)
        } catch {
            guard isCurrent() else { return }
            tagsError = "Tags indisponibles : \(error.localizedDescription)"
            isLoadingTags = false
        }
    }

    private func resolveCategories(driveId: Int) {
        guard let membership = file?.categories else { return }
        if membership.isEmpty {
            categories = []
            tagsError = nil
            isLoadingTags = false
            return
        }
        guard CategoryLibrary.shared.hasLoaded(for: driveId) else { return }
        let library = CategoryLibrary.shared.categories(for: driveId)
        categories = membership.compactMap { library[$0.categoryId] }
        tagsError = categories.count == Set(membership.map(\.categoryId)).count
            ? nil : "Certains tags ne sont plus disponibles."
        isLoadingTags = false
    }
}
