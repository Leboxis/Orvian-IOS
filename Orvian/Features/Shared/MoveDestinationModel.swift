import Foundation
import Observation

/// Navigation belongs to the picker, independently of the browser behind it.
@MainActor @Observable
final class MoveDestinationModel {
    private(set) var directory: DriveFile?
    private(set) var isBusy = false
    private(set) var reloadRevision = 0
    var error: String?
    private let files: [DriveFile]
    private let credential: String?
    private let currentCredential: () -> String?
    private let loadDirectory: (Int) async throws -> DriveFile
    private let createDirectory: (Int, String) async throws -> Void
    private var knownDirectories: [Int: DriveFile] = [:]
    private var safeDirectories: Set<Int> = [1]

    init(files: [DriveFile], initialDirectory: DriveFile?, credential: String?,
         currentCredential: @escaping () -> String?,
         loadDirectory: @escaping (Int) async throws -> DriveFile,
         createDirectory: @escaping (Int, String) async throws -> Void) {
        self.files = files
        let start: DriveFile?
        if let parent = files.first?.parentId, let initialDirectory, parent != initialDirectory.id {
            start = nil
        } else {
            start = initialDirectory
        }
        self.directory = start
        self.credential = credential
        self.currentCredential = currentCredential
        self.loadDirectory = loadDirectory
        self.createDirectory = createDirectory
        if let start { knownDirectories[start.id] = start }
    }

    convenience init(driveId: Int, files: [DriveFile], initialDirectory: DriveFile?) {
        let service = KDriveService()
        let credential = TokenStore.credentialFingerprint()
        self.init(files: files, initialDirectory: initialDirectory, credential: credential,
                  currentCredential: TokenStore.credentialFingerprint,
                  loadDirectory: { try await service.fileInfo(driveId: driveId, fileId: $0, credentialFingerprint: credential) },
                  createDirectory: { try await service.createFolder(driveId: driveId, directoryId: $0, name: $1,
                                                                     credentialFingerprint: credential) })
    }

    var canGoUp: Bool { directory.map { $0.id != 1 } ?? false }
    private func checkSession() throws {
        try Task.checkCancellation()
        guard credential != nil, credential == currentCredential() else { throw CancellationError() }
    }

    private func folder(_ id: Int) async throws -> DriveFile {
        try checkSession()
        if id == 1 { return .root(name: "Racine du drive") }
        if let cached = knownDirectories[id] { return cached }
        let result = try await loadDirectory(id)
        try checkSession()
        guard result.id == id && result.isDirectory else { throw APIError.invalidResponse }
        knownDirectories[id] = result
        return result
    }

    func loadStart() async {
        guard directory == nil, !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try checkSession()
            guard let first = files.first else { throw APIError.invalidResponse }
            let origin = first.parentId == nil ? try await loadDirectory(first.id) : first
            try checkSession()
            guard let parent = origin.parentId else { throw APIError.invalidResponse }
            directory = try await folder(parent)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func open(_ folder: DriveFile) {
        guard !isBusy, folder.isDirectory, credential != nil, credential == currentCredential() else { return }
        if let directory { knownDirectories[directory.id] = directory }
        directory = folder; error = nil
    }

    func goUp() async {
        guard let directory, canGoUp, !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try checkSession()
            let current = directory.parentId == nil ? try await loadDirectory(directory.id) : directory
            try checkSession()
            guard let parent = current.parentId, parent != current.id else { throw APIError.invalidResponse }
            self.directory = try await folder(parent)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    /// Relative opening can start inside a selected ancestor in a mixed
    /// Favorites selection. Verify that chain before sending any move.
    func confirmedDestination() async -> DriveFile? {
        guard let destination = directory, !isBusy else { return nil }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try checkSession()
            let excluded = Set(files.filter(\.isDirectory).map(\.id))
            if excluded.isEmpty { return destination }
            var current = destination
            var visited: Set<Int> = []
            while true {
                guard !excluded.contains(current.id) else {
                    self.error = "Un dossier ne peut pas être déplacé dans lui-même ou dans un sous-dossier."
                    return nil
                }
                if safeDirectories.contains(current.id) {
                    safeDirectories.formUnion(visited)
                    return destination
                }
                guard visited.insert(current.id).inserted else { throw APIError.invalidResponse }
                let info = current.parentId == nil ? try await loadDirectory(current.id) : current
                try checkSession()
                guard let parent = info.parentId, parent != current.id else { throw APIError.invalidResponse }
                current = try await folder(parent)
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        return nil
    }

    @discardableResult
    func createFolder(name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let directory, !name.isEmpty, !isBusy else { return false }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try checkSession()
            try await createDirectory(directory.id, name)
            try checkSession()
            reloadRevision &+= 1
            return true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        return false
    }
}
