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

/// Gestionnaire centralisé des uploads avec suivi en temps réel.
@MainActor
@Observable
final class UploadManager {
    static let shared = UploadManager()

    var tasks: [UploadTaskItem] = []
    var isPillVisible: Bool = false

    private let service = KDriveService()
    private var hidePillTask: Task<Void, Never>?

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
            case .failed: return sum + 1.0
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
            let item = items[i]
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let name = count == 1 ? "Photo.\(ext)" : "Média \(i + 1).\(ext)"
            newTasks.append(UploadTaskItem(fileName: name, totalBytes: 0, status: .inProgress(progress: 0.05)))
        }
        tasks.append(contentsOf: newTasks)

        Task {
            var uploadedFiles: [DriveFile] = []
            for (index, item) in items.enumerated() {
                let taskId = newTasks[index].id
                guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { continue }

                let contentType = item.supportedContentTypes.first ?? .data
                let ext = contentType.preferredFilenameExtension ?? "jpg"
                let realName = "Import-\(Int(Date().timeIntervalSince1970))-\(index + 1).\(ext)"

                tasks[taskIndex].fileName = realName
                tasks[taskIndex].status = .inProgress(progress: 0.15)

                var payload: UploadPayload? = nil
                if let picked = try? await item.loadTransferable(type: PickedPhotoTransferable.self) {
                    payload = await UploadFileIO.payload(forTemporaryURL: picked.url, fileName: realName)
                } else if let data = try? await item.loadTransferable(type: Data.self) {
                    payload = await UploadFileIO.writeToTemporaryDirectory(data: data, fileName: realName)
                }

                if let payload {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx].fileName = realName
                        tasks[curIdx].totalBytes = payload.totalBytes
                        tasks[curIdx].status = .inProgress(progress: 0.2)
                    }
                    if let uploadedFile = await uploadSingleFile(taskId: taskId, driveId: driveId, directoryId: directoryId, payload: payload) {
                        uploadedFiles.append(uploadedFile)
                    }
                } else {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx].status = .failed(message: "Échec de lecture du média")
                    }
                }
            }

            onDone?(uploadedFiles)
            schedulePillAutoDismiss()
        }
    }

    /// Import immédiat et asynchrone des documents (la bulle s'affiche instantanément)
    func enqueueDocuments(driveId: Int, directoryId: Int, urls: [URL], onDone: (([DriveFile]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let newTasks = urls.map { UploadTaskItem(fileName: $0.lastPathComponent, totalBytes: 0, status: .inProgress(progress: 0.05)) }
        tasks.append(contentsOf: newTasks)

        Task {
            var uploadedFiles: [DriveFile] = []
            for (index, url) in urls.enumerated() {
                let taskId = newTasks[index].id
                guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { continue }
                tasks[taskIndex].status = .inProgress(progress: 0.15)

                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let payload = await UploadFileIO.copyToTemporaryDirectory(sourceURL: url, fileName: url.lastPathComponent)

                if let payload {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx].totalBytes = payload.totalBytes
                        tasks[curIdx].status = .inProgress(progress: 0.2)
                    }
                    if let uploadedFile = await uploadSingleFile(taskId: taskId, driveId: driveId, directoryId: directoryId, payload: payload) {
                        uploadedFiles.append(uploadedFile)
                    }
                } else {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx].status = .failed(message: "Échec de copie du fichier")
                    }
                }
            }

            onDone?(uploadedFiles)
            schedulePillAutoDismiss()
        }
    }

    /// Enfile et exécute une liste de fichiers à uploader par streaming direct depuis le disque.
    func enqueue(driveId: Int, directoryId: Int, files: [UploadPayload], onDone: (([DriveFile]) -> Void)? = nil) {
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let newTasks = files.map { UploadTaskItem(fileName: $0.fileName, totalBytes: $0.totalBytes) }
        tasks.append(contentsOf: newTasks)

        Task {
            var uploadedFiles: [DriveFile] = []
            for (index, file) in files.enumerated() {
                let taskId = newTasks[index].id
                if let uploadedFile = await uploadSingleFile(
                    taskId: taskId,
                    driveId: driveId,
                    directoryId: directoryId,
                    payload: file
                ) {
                    uploadedFiles.append(uploadedFile)
                }
            }

            onDone?(uploadedFiles)
            schedulePillAutoDismiss()
        }
    }

    /// Rétrocompatibilité : convertit les données en fichiers temporaires avant enfilage.
    func enqueue(driveId: Int, directoryId: Int, files: [(data: Data, name: String)], onDone: (([DriveFile]) -> Void)? = nil) {
        Task {
            var payloads: [UploadPayload] = []
            for item in files {
                if let payload = await UploadFileIO.writeToTemporaryDirectory(data: item.data, fileName: item.name) {
                    payloads.append(payload)
                }
            }
            enqueue(driveId: driveId, directoryId: directoryId, files: payloads, onDone: onDone)
        }
    }

    private func uploadSingleFile(taskId: UUID, driveId: Int, directoryId: Int, payload: UploadPayload) async -> DriveFile? {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            if payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        tasks[index].status = .inProgress(progress: 0.15)

        do {
            tasks[index].status = .inProgress(progress: 0.2)
            let uploadedFile = try await service.uploadFile(
                driveId: driveId,
                directoryId: directoryId,
                fileURL: payload.fileURL,
                fileName: payload.fileName,
                totalSize: payload.totalBytes,
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        guard let self,
                              let currentIndex = self.tasks.firstIndex(where: { $0.id == taskId })
                        else { return }
                        guard case .inProgress = self.tasks[currentIndex].status else { return }
                        // Les 20 premiers pourcents représentent la préparation
                        // locale ; les 80 suivants correspondent aux octets envoyés.
                        self.tasks[currentIndex].status = .inProgress(progress: 0.2 + fraction * 0.8)
                    }
                }
            )
            tasks[index].status = .completed
            if payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return uploadedFile
        } catch {
            let desc = (error as? APIError)?.errorDescription ?? error.localizedDescription
            tasks[index].status = .failed(message: desc)
        }

        if payload.isTemporary {
            await UploadFileIO.removeTemporaryFile(payload.fileURL)
        }
        return nil
    }

    func clearCompleted() {
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
