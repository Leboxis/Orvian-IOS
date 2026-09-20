import Foundation
import SwiftUI
import Observation
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable

/// Représentation fichier sur disque pour l'import Transferable PhotosUI
private struct PickedPhotoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .item) { picked in
            SentTransferredFile(picked.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return PickedPhotoTransferable(url: tempURL)
        }
    }
}

/// Statut d'un élément d'upload.
enum UploadStatus: Equatable {
    case queued
    case inProgress(progress: Double)
    case completed
    case failed(message: String)
}

/// Filtre thread-safe des rappels de progression : coalesce les ticks et
/// ordonne leur application. Une nouvelle tentative repart de zéro sans qu'un
/// ancien tick puisse remettre la barre à la valeur précédente.
private final class UploadProgressFilter: @unchecked Sendable {
    struct Update: Sendable {
        let attempt: Int
        let sequence: Int
        let fraction: Double
    }

    private let lock = NSLock()
    private var attempt = 0
    private var sequence = 0
    private var lastAppliedSequence = -1
    private var lastReported = 0.0
    /// Pas minimal entre deux mises à jour d'interface (~1 % de la barre).
    private let step = 0.01

    func beginAttempt(_ newAttempt: Int) -> Update {
        lock.lock()
        defer { lock.unlock() }
        attempt = newAttempt
        sequence = 0
        lastAppliedSequence = -1
        lastReported = 0
        return Update(attempt: attempt, sequence: sequence, fraction: 0)
    }

    func update(_ fraction: Double) -> Update? {
        lock.lock()
        defer { lock.unlock() }
        guard fraction > lastReported + step || fraction >= 1 else { return nil }
        if fraction > lastReported {
            lastReported = fraction
        }
        sequence += 1
        return Update(attempt: attempt, sequence: sequence, fraction: fraction)
    }

    func shouldApply(_ update: Update) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard update.attempt == attempt, update.sequence > lastAppliedSequence else { return false }
        lastAppliedSequence = update.sequence
        return true
    }
}

/// Tâche d'upload individuelle.
struct UploadTaskItem: Identifiable, Equatable {
    let id: UUID
    var fileName: String
    var totalBytes: Int
    var status: UploadStatus
    let date: Date

    init(fileName: String, totalBytes: Int, status: UploadStatus = .queued) {
        self.id = UUID()
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.status = status
        self.date = Date()
    }
}

/// I/O de préparation des imports. Toutes les opérations potentiellement
/// longues s'exécutent hors du MainActor ; seules les mutations d'interface
/// restent dans UploadManager.
private enum UploadFileIO {
    static func payload(forTemporaryURL url: URL, fileName: String) async -> UploadPayload {
        await Task.detached(priority: .utility) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return UploadPayload(fileURL: url, fileName: fileName, totalBytes: size, isTemporary: true)
        }.value
    }

    static func copyToTemporaryDirectory(sourceURL: URL, fileName: String) async -> UploadPayload? {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + "_" + fileName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return UploadPayload(fileURL: destination, fileName: fileName, totalBytes: size, isTemporary: true)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        }.value
    }

    static func writeToTemporaryDirectory(data: Data, fileName: String) async -> UploadPayload? {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + "_" + fileName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                return UploadPayload(fileURL: destination, fileName: fileName, totalBytes: data.count, isTemporary: true)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        }.value
    }

    static func removeTemporaryFile(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    static func removeTemporaryFiles(_ urls: [URL]) async {
        await Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }
}

/// Élément d'upload préparé sur disque (aucun buffer binaire volumineux en mémoire).
struct UploadPayload: Sendable {
    let fileURL: URL
    let fileName: String
    let totalBytes: Int
    let isTemporary: Bool

    init(fileURL: URL, fileName: String, totalBytes: Int, isTemporary: Bool = true) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.isTemporary = isTemporary
    }
}

private enum UploadRetrySource {
    case photo(item: PhotosPickerItem, itemIndex: Int)
    case document(URL)
    case payload(UploadPayload)
}

private struct UploadRetryContext {
    let driveId: Int
    let directoryId: Int
    let onDone: (([DriveFile]) -> Void)?
    var source: UploadRetrySource
}

/// Gestionnaire centralisé des uploads avec suivi en temps réel.
@MainActor
@Observable
final class UploadManager {
    static let shared = UploadManager()

    var tasks: [UploadTaskItem] = []
    var isPillVisible: Bool = false

    private let service = KDriveService()
    private var hidePillTask: Task<Void, Never>?
    private var uploadJobs: [UUID: Task<Void, Never>] = [:]
    private var retryContexts: [UUID: UploadRetryContext] = [:]
    /// L'API kDrive traite chaque upload de manière indépendante (session
    /// dédiée aux gros fichiers), plusieurs fichiers peuvent donc partir en
    /// parallèle sans verrou côté serveur.
    private static let maxConcurrentUploads = 4

    private init() {}

    var activeTasksCount: Int {
        tasks.filter {
            switch $0.status {
            case .queued, .inProgress: return true
            case .completed, .failed: return false
            }
        }.count
    }

    var completedTasksCount: Int {
        tasks.filter {
            if case .completed = $0.status { return true }
            return false
        }.count
    }

    var hasFailures: Bool {
        tasks.contains {
            if case .failed = $0.status { return true }
            return false
        }
    }

    var overallProgress: Double {
        guard !tasks.isEmpty else { return 0 }
        let total = tasks.reduce(0.0) { sum, task in
            switch task.status {
            case .queued: return sum + 0
            case let .inProgress(p): return sum + p
            case .completed: return sum + 1.0
            case .failed: return sum
            }
        }
        return total / Double(tasks.count)
    }

    /// Import immédiat et asynchrone des photos/vidéos depuis PhotosPicker (la bulle s'affiche instantanément)
    func enqueuePhotos(driveId: Int, directoryId: Int, items: [PhotosPickerItem], onDone: (([DriveFile]) -> Void)? = nil) {
        guard !items.isEmpty else { return }
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let count = items.count
        var newTasks: [UploadTaskItem] = []
        for i in 0..<count {
            // Nom d'attente neutre : le vrai nom d'origine n'est connu qu'après
            // `loadTransferable` (asynchrone). Pas de fausse extension.
            let name = count == 1 ? "Préparation de la photo…" : "Préparation du média \(i + 1)…"
            newTasks.append(UploadTaskItem(fileName: name, totalBytes: 0, status: .inProgress(progress: 0.05)))
        }
        tasks.append(contentsOf: newTasks)
        for (index, item) in items.enumerated() {
            retryContexts[newTasks[index].id] = UploadRetryContext(
                driveId: driveId,
                directoryId: directoryId,
                onDone: onDone,
                source: .photo(item: item, itemIndex: index)
            )
        }

        let jobID = UUID()
        uploadJobs[jobID] = Task { [weak self] in
            guard let self else { return }
            defer { self.uploadJobs.removeValue(forKey: jobID) }

            let work: [(item: PhotosPickerItem, taskId: UUID, itemIndex: Int)] = items.enumerated().map { entry in
                (item: entry.element, taskId: newTasks[entry.offset].id, itemIndex: entry.offset)
            }
            let results = await mapBounded(work, concurrency: Self.maxConcurrentUploads) { entry in
                await self.prepareAndUploadPhoto(
                    item: entry.item,
                    taskId: entry.taskId,
                    itemIndex: entry.itemIndex,
                    driveId: driveId,
                    directoryId: directoryId
                )
            }
            let uploadedFiles = results.compactMap { $0 }

            guard !Task.isCancelled else { return }
            onDone?(uploadedFiles)
            self.schedulePillAutoDismiss()
        }
    }

    /// Prépare (I/O disque) puis téléverse une photo/vidéo PhotosPicker.
    /// Le nom d'origine (ex. IMG_1234.HEIC) est préservé quand le système le
    /// fournit via l'URL transférée ; sinon repli daté lisible.
    private func prepareAndUploadPhoto(
        item: PhotosPickerItem,
        taskId: UUID,
        itemIndex: Int,
        driveId: Int,
        directoryId: Int
    ) async -> DriveFile? {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }

        let contentType = item.supportedContentTypes.first ?? .data
        let ext = contentType.preferredFilenameExtension ?? "jpg"

        tasks[taskIndex].status = .inProgress(progress: 0.15)

        var payload: UploadPayload? = nil
        if let picked = try? await item.loadTransferable(type: PickedPhotoTransferable.self) {
            let realName = Self.photoFileName(fromTemporaryURL: picked.url, fallbackExt: ext, itemIndex: itemIndex)
            payload = await UploadFileIO.payload(forTemporaryURL: picked.url, fileName: realName)
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            let realName = Self.datedFallbackPhotoName(ext: ext, itemIndex: itemIndex)
            payload = await UploadFileIO.writeToTemporaryDirectory(data: data, fileName: realName)
        }

        guard !Task.isCancelled else {
            if let payload, payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        guard let payload else {
            // `PhotosPickerItem` ne survit pas forcément à la fermeture du
            // sélecteur : proposer "Réessayer" sur le même item serait un
            // échec garanti. On retire le contexte pour ne pas afficher le
            // bouton, avec un message qui invite à resélectionner le média.
            if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[curIdx].status = .failed(message: "Échec de lecture du média — resélectionnez-le dans Photos pour réessayer")
            }
            retryContexts.removeValue(forKey: taskId)
            return nil
        }

        if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[curIdx].fileName = payload.fileName
            tasks[curIdx].totalBytes = payload.totalBytes
            tasks[curIdx].status = .inProgress(progress: 0.2)
        }
        guard var retryContext = retryContexts[taskId] else {
            if payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        retryContext.source = .payload(payload)
        retryContexts[taskId] = retryContext
        return await uploadSingleFile(taskId: taskId, driveId: driveId, directoryId: directoryId, payload: payload)
    }

    /// Nom d'origine extrait de l'URL transférée (`<uuid>_<original>`).
    /// Conserve ex. `IMG_1234.HEIC` au lieu d'inventer `Photo.jpg`.
    private static func photoFileName(fromTemporaryURL url: URL, fallbackExt: String, itemIndex: Int) -> String {
        let last = url.lastPathComponent
        let original: String
        if let underscore = last.firstIndex(of: "_") {
            let suffix = String(last[last.index(after: underscore)...])
            original = suffix.isEmpty ? last : suffix
        } else {
            original = last
        }
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return datedFallbackPhotoName(ext: fallbackExt, itemIndex: itemIndex)
        }
        if URL(fileURLWithPath: trimmed).pathExtension.isEmpty {
            return "\(trimmed).\(fallbackExt)"
        }
        return trimmed
    }

    /// Repli lisible quand le système ne fournit aucun nom (`Photo_20250919_…`).
private static let fallbackDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private static func datedFallbackPhotoName(ext: String, itemIndex: Int) -> String {
        let stamp = fallbackDateFormatter.string(from: Date())
        return "Photo_\(stamp)_\(itemIndex + 1).\(ext)"
    }

    /// Import immédiat et asynchrone des documents (la bulle s'affiche instantanément)
    func enqueueDocuments(driveId: Int, directoryId: Int, urls: [URL], onDone: (([DriveFile]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let newTasks = urls.map { UploadTaskItem(fileName: $0.lastPathComponent, totalBytes: 0, status: .inProgress(progress: 0.05)) }
        tasks.append(contentsOf: newTasks)
        for (index, url) in urls.enumerated() {
            retryContexts[newTasks[index].id] = UploadRetryContext(
                driveId: driveId,
                directoryId: directoryId,
                onDone: onDone,
                source: .document(url)
            )
        }

        let jobID = UUID()
        uploadJobs[jobID] = Task { [weak self] in
            guard let self else { return }
            defer { self.uploadJobs.removeValue(forKey: jobID) }

            let work: [(url: URL, taskId: UUID)] = urls.enumerated().map { entry in
                (url: entry.element, taskId: newTasks[entry.offset].id)
            }
            let results = await mapBounded(work, concurrency: Self.maxConcurrentUploads) { entry in
                await self.prepareAndUploadDocument(
                    url: entry.url,
                    taskId: entry.taskId,
                    driveId: driveId,
                    directoryId: directoryId
                )
            }
            let uploadedFiles = results.compactMap { $0 }

            guard !Task.isCancelled else { return }
            onDone?(uploadedFiles)
            self.schedulePillAutoDismiss()
        }
    }

    /// Prépare (copie temporaire) puis téléverse un document.
    private func prepareAndUploadDocument(url: URL, taskId: UUID, driveId: Int, directoryId: Int) async -> DriveFile? {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        tasks[taskIndex].status = .inProgress(progress: 0.15)

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let payload = await UploadFileIO.copyToTemporaryDirectory(sourceURL: url, fileName: url.lastPathComponent)

        guard !Task.isCancelled else {
            if let payload, payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        guard let payload else {
            if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[curIdx].status = .failed(message: "Échec de copie du fichier")
            }
            return nil
        }

        if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[curIdx].totalBytes = payload.totalBytes
            tasks[curIdx].status = .inProgress(progress: 0.2)
        }
        guard var retryContext = retryContexts[taskId] else {
            if payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        retryContext.source = .payload(payload)
        retryContexts[taskId] = retryContext
        return await uploadSingleFile(taskId: taskId, driveId: driveId, directoryId: directoryId, payload: payload)
    }

    private func uploadSingleFile(taskId: UUID, driveId: Int, directoryId: Int, payload: UploadPayload) async -> DriveFile? {
        guard !Task.isCancelled else {
            retryContexts.removeValue(forKey: taskId)
            if payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            retryContexts.removeValue(forKey: taskId)
            if payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        tasks[index].status = .inProgress(progress: 0.15)

        var result: DriveFile?
        do {
            tasks[index].status = .inProgress(progress: 0.2)
            let progressFilter = UploadProgressFilter()
            let uploadedFile = try await service.uploadFile(
                driveId: driveId,
                directoryId: directoryId,
                fileURL: payload.fileURL,
                fileName: payload.fileName,
                totalSize: payload.totalBytes,
                attemptStarted: { [weak self] attempt in
                    let update = progressFilter.beginAttempt(attempt)
                    Task { @MainActor in
                        self?.applyProgress(update, filter: progressFilter, taskId: taskId)
                    }
                },
                progress: { [weak self] fraction in
                    guard let update = progressFilter.update(fraction) else { return }
                    Task { @MainActor in
                        self?.applyProgress(update, filter: progressFilter, taskId: taskId)
                    }
                }
            )
            try Task.checkCancellation()
            guard let currentIndex = tasks.firstIndex(where: { $0.id == taskId }) else {
                throw CancellationError()
            }
            tasks[currentIndex].status = .completed
            retryContexts.removeValue(forKey: taskId)
            result = uploadedFile
            if uploadedFile.fileKind.supportsThumbnail {
                let uploadedFileID = uploadedFile.id
                Task.detached(priority: .utility) {
                    await ThumbnailProvider.shared.primeUploadedThumbnail(
                        driveId: driveId,
                        fileId: uploadedFileID
                    )
                }
            }
        } catch {
            if !Task.isCancelled,
               let currentIndex = tasks.firstIndex(where: { $0.id == taskId }) {
                let desc = (error as? APIError)?.errorDescription ?? error.localizedDescription
                tasks[currentIndex].status = .failed(message: desc)
                if error is UploadOutcomeUnknown {
                    // Aucun bouton Réessayer si le premier envoi a pu aboutir.
                    retryContexts.removeValue(forKey: taskId)
                }
            } else {
                retryContexts.removeValue(forKey: taskId)
            }
        }

        let shouldRemoveTemporaryFile = result != nil || Task.isCancelled || retryContexts[taskId] == nil
        if shouldRemoveTemporaryFile && payload.isTemporary {
            await UploadFileIO.removeTemporaryFile(payload.fileURL)
        }
        return result
    }

    private func applyProgress(_ update: UploadProgressFilter.Update, filter: UploadProgressFilter, taskId: UUID) {
        guard filter.shouldApply(update),
              let index = tasks.firstIndex(where: { $0.id == taskId }),
              case .inProgress = tasks[index].status
        else { return }
        // Les 20 premiers pourcents représentent la préparation locale ; les
        // 80 suivants correspondent aux octets envoyés lors de cette tentative.
        tasks[index].status = .inProgress(progress: 0.2 + min(max(update.fraction, 0), 1) * 0.8)
    }

    func canRetry(taskId: UUID) -> Bool {
        guard retryContexts[taskId] != nil,
              let task = tasks.first(where: { $0.id == taskId }),
              case .failed = task.status
        else { return false }
        return true
    }

    func retryUpload(taskId: UUID) {
        guard canRetry(taskId: taskId),
              let index = tasks.firstIndex(where: { $0.id == taskId }),
              let context = retryContexts[taskId]
        else { return }

        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true
        tasks[index].status = .queued

        let jobID = UUID()
        uploadJobs[jobID] = Task { [weak self] in
            guard let self else { return }
            defer { self.uploadJobs.removeValue(forKey: jobID) }

            let uploadedFile: DriveFile?
            switch context.source {
            case let .photo(item, itemIndex):
                uploadedFile = await self.prepareAndUploadPhoto(
                    item: item,
                    taskId: taskId,
                    itemIndex: itemIndex,
                    driveId: context.driveId,
                    directoryId: context.directoryId
                )
            case let .document(url):
                uploadedFile = await self.prepareAndUploadDocument(
                    url: url,
                    taskId: taskId,
                    driveId: context.driveId,
                    directoryId: context.directoryId
                )
            case let .payload(payload):
                uploadedFile = await self.uploadSingleFile(
                    taskId: taskId,
                    driveId: context.driveId,
                    directoryId: context.directoryId,
                    payload: payload
                )
            }

            guard !Task.isCancelled else { return }
            if let uploadedFile {
                context.onDone?([uploadedFile])
            }
            self.schedulePillAutoDismiss()
        }
    }

    private func discardRetryContexts(for taskIDs: Set<UUID>) {
        let urls = taskIDs.compactMap { taskID -> URL? in
            guard let context = retryContexts.removeValue(forKey: taskID),
                  case let .payload(payload) = context.source,
                  payload.isTemporary
            else { return nil }
            return payload.fileURL
        }
        guard !urls.isEmpty else { return }
        Task {
            await UploadFileIO.removeTemporaryFiles(urls)
        }
    }

    /// Utilisé à la déconnexion : aucune tâche d'un ancien compte ne doit
    /// continuer ni rester visible dans la session suivante.
    func cancelAllAndClear() {
        hidePillTask?.cancel()
        hidePillTask = nil
        for job in uploadJobs.values {
            job.cancel()
        }
        discardRetryContexts(for: Set(retryContexts.keys))
        uploadJobs.removeAll()
        tasks.removeAll()
        isPillVisible = false
    }

    func clearCompleted() {
        let discardedTaskIDs = Set(tasks.compactMap { task -> UUID? in
            switch task.status {
            case .completed, .failed: return task.id
            case .queued, .inProgress: return nil
            }
        })
        discardRetryContexts(for: discardedTaskIDs)
        tasks.removeAll {
            switch $0.status {
            case .completed, .failed: return true
            case .queued, .inProgress: return false
            }
        }
        if tasks.isEmpty {
            isPillVisible = false
        }
    }

    private func schedulePillAutoDismiss() {
        hidePillTask?.cancel()
        hidePillTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if activeTasksCount == 0 && !hasFailures {
                withAnimation(.snappy(duration: 0.3)) {
                    isPillVisible = false
                }
            }
        }
    }
}
