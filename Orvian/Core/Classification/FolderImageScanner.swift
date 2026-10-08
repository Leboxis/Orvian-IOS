import Foundation
import Observation

struct FolderScanProgress {
    enum Phase: Equatable { case enumerating, analyzing, completed, cancelled, failed }
    let directoryId: Int
    let directoryName: String
    let driveId: Int
    var phase: Phase = .enumerating
    var total: Int?
    var processed = 0
    var failed = 0
    var reused = 0
    var errorMessage: String?
}

/// One foreground scan. Its captured folder is independent of UI filtering.
@MainActor
@Observable
final class FolderImageScanner {
    static let shared = FolderImageScanner()
    private(set) var progress: FolderScanProgress?
    private(set) var resultScores: [Float] = []
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private let store: ImageClassificationStore
    private let credential: () -> String?
    private let page: (Int, Int, String?) async throws -> CursorPage<DriveFile>
    private let imageData: (Int, Int) async throws -> Data
    private let prepare: () async throws -> Void
    private let classify: (Data) async throws -> Float

    var isRunning: Bool {
        progress?.phase == .enumerating || progress?.phase == .analyzing
    }

    var sfwCount: Int { resultScores.reduce(0) { $0 + ($1 < store.threshold ? 1 : 0) } }
    var nsfwCount: Int { resultScores.count - sfwCount }

    init(store: ImageClassificationStore? = nil,
         credential: @escaping () -> String? = { TokenStore.credentialFingerprint() },
         page: @escaping (Int, Int, String?) async throws -> CursorPage<DriveFile> = { drive, folder, cursor in
             try await KDriveService().page(.directory(folder), driveId: drive, cursor: cursor, forceNetwork: true)
         },
         imageData: @escaping (Int, Int) async throws -> Data = { drive, file in
             try await ThumbnailProvider.shared.classificationImageData(driveId: drive, fileId: file)
         },
         prepare: @escaping () async throws -> Void = { try await NSFWImageClassifier.shared.prepare() },
         classify: @escaping (Data) async throws -> Float = { try await NSFWImageClassifier.shared.classify(imageData: $0) }) {
        self.store = store ?? .shared
        self.credential = credential
        self.page = page
        self.imageData = imageData
        self.prepare = prepare
        self.classify = classify
    }

    func start(driveId: Int, directory: DriveFile) {
        guard !isRunning, directory.isDirectory, let capturedCredential = credential() else { return }
        generation &+= 1
        let capturedGeneration = generation
        resultScores = []
        progress = FolderScanProgress(directoryId: directory.id, directoryName: directory.name, driveId: driveId)
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(driveId: driveId, directoryId: directory.id,
                           credential: capturedCredential, generation: capturedGeneration)
        }
    }

    func cancel() {
        guard isRunning else { return }
        generation &+= 1
        task?.cancel()
        task = nil
        progress?.phase = .cancelled
        let store = store
        Task { try? await store.flush() }
    }

    func resetSession() {
        cancel()
        generation &+= 1
        progress = nil
        resultScores = []
        task = nil
    }

    private func check(credential captured: String, generation capturedGeneration: Int) throws {
        try Task.checkCancellation()
        guard generation == capturedGeneration, credential() == captured else { throw CancellationError() }
    }

    private func run(driveId: Int, directoryId: Int, credential captured: String, generation capturedGeneration: Int) async {
        defer { if generation == capturedGeneration { task = nil } }
        do {
            try check(credential: captured, generation: capturedGeneration)
            await store.load(credentialFingerprint: captured)
            try check(credential: captured, generation: capturedGeneration)
            var images: [DriveFile] = []
            var ids = Set<Int>()
            var cursors = Set<String>()
            var cursor: String?
            while true {
                try check(credential: captured, generation: capturedGeneration)
                let response = try await page(driveId, directoryId, cursor)
                try check(credential: captured, generation: capturedGeneration)
                guard let items = response.data else { throw ClassificationError.invalidPagination }
                for image in items where image.isImage {
                    if ids.insert(image.id).inserted { images.append(image) }
                }
                guard response.hasMore ?? (response.cursor != nil) else { break }
                guard let next = response.cursor, !next.isEmpty, cursors.insert(next).inserted else {
                    throw ClassificationError.invalidPagination
                }
                cursor = next
            }
            progress?.total = images.count
            progress?.phase = .analyzing
            if !images.isEmpty {
                try await prepare()
                try check(credential: captured, generation: capturedGeneration)
            }
            for file in images {
                try check(credential: captured, generation: capturedGeneration)
                if ImageContentRevision(file: file) != nil,
                   let score = store.score(driveId: driveId, file: file) {
                    resultScores.append(score)
                    progress?.reused += 1
                } else {
                    do {
                        let data = try await imageData(driveId, file.id)
                        try check(credential: captured, generation: capturedGeneration)
                        let score = try await classify(data)
                        try check(credential: captured, generation: capturedGeneration)
                        try await store.record(score: score, file: file, driveId: driveId,
                                               credentialFingerprint: captured, modelVersion: NSFWImageClassifier.modelVersion)
                        try check(credential: captured, generation: capturedGeneration)
                        resultScores.append(score)
                    } catch {
                        // A late response cannot become an error or score in a new scan.
                        try check(credential: captured, generation: capturedGeneration)
                        if error is CancellationError { throw error }
                        progress?.failed += 1
                    }
                }
                progress?.processed += 1
            }
            try await store.flush()
            try check(credential: captured, generation: capturedGeneration)
            progress?.phase = .completed
        } catch {
            guard generation == capturedGeneration else { return }
            if error is CancellationError || credential() != captured {
                progress?.phase = .cancelled
            } else {
                progress?.phase = .failed
                progress?.errorMessage = error.localizedDescription
            }
        }
    }
}
