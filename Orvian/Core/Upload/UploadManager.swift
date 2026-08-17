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
    let fileName: String
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
    func enqueuePhotos(driveId: Int, directoryId: Int, items: [PhotosPickerItem], onDone: (() -> Void)? = nil) {
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
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            for (index, item) in items.enumerated() {
                let taskId = newTasks[index].id
                guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { continue }

                let contentType = item.supportedContentTypes.first ?? .data
                let ext = contentType.preferredFilenameExtension ?? "jpg"
                let realName = "Import-\(Int(Date().timeIntervalSince1970))-\(index + 1).\(ext)"

                tasks[taskIndex] = UploadTaskItem(fileName: realName, totalBytes: 0, status: .inProgress(progress: 0.15))

                var payload: UploadPayload? = nil
                if let picked = try? await item.loadTransferable(type: PickedPhotoTransferable.self) {
                    let size = (try? picked.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    payload = UploadPayload(fileURL: picked.url, fileName: realName, totalBytes: size, isTemporary: true)
                } else if let data = try? await item.loadTransferable(type: Data.self) {
                    let tempURL = tempDir.appendingPathComponent(realName)
                    try? FileManager.default.removeItem(at: tempURL)
                    do {
                        try data.write(to: tempURL, options: .atomic)
                        payload = UploadPayload(fileURL: tempURL, fileName: realName, totalBytes: data.count, isTemporary: true)
                    } catch {}
                }

                if let payload {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx] = UploadTaskItem(fileName: realName, totalBytes: payload.totalBytes, status: .inProgress(progress: 0.2))
                    }
                    await uploadSingleFile(taskId: taskId, driveId: driveId, directoryId: directoryId, payload: payload)
                } else {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx].status = .failed(message: "Échec de lecture du média")
                    }
                }
            }

            onDone?()
            schedulePillAutoDismiss()
        }
    }

    /// Import immédiat et asynchrone des documents (la bulle s'affiche instantanément)
    func enqueueDocuments(driveId: Int, directoryId: Int, urls: [URL], onDone: (() -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let newTasks = urls.map { UploadTaskItem(fileName: $0.lastPathComponent, totalBytes: 0, status: .inProgress(progress: 0.05)) }
        tasks.append(contentsOf: newTasks)

        Task {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

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

                let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)

                var payload: UploadPayload? = nil
                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    payload = UploadPayload(fileURL: tempURL, fileName: url.lastPathComponent, totalBytes: size, isTemporary: true)
                } catch {}

                if let payload {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx] = UploadTaskItem(fileName: url.lastPathComponent, totalBytes: payload.totalBytes, status: .inProgress(progress: 0.2))
                    }
                    await uploadSingleFile(taskId: taskId, driveId: driveId, directoryId: directoryId, payload: payload)
                } else {
                    if let curIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[curIdx].status = .failed(message: "Échec de copie du fichier")
                    }
                }
            }

            onDone?()
            schedulePillAutoDismiss()
        }
    }

    /// Enfile et exécute une liste de fichiers à uploader par streaming direct depuis le disque.
    func enqueue(driveId: Int, directoryId: Int, files: [UploadPayload], onDone: (() -> Void)? = nil) {
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let newTasks = files.map { UploadTaskItem(fileName: $0.fileName, totalBytes: $0.totalBytes) }
        tasks.append(contentsOf: newTasks)

        Task {
            for (index, file) in files.enumerated() {
                let taskId = newTasks[index].id
                await uploadSingleFile(
                    taskId: taskId,
                    driveId: driveId,
                    directoryId: directoryId,
                    payload: file
                )
            }

            onDone?()
            schedulePillAutoDismiss()
        }
    }

    /// Rétrocompatibilité : convertit les données en fichiers temporaires avant enfilage.
    func enqueue(driveId: Int, directoryId: Int, files: [(data: Data, name: String)], onDone: (() -> Void)? = nil) {
        let payloads: [UploadPayload] = files.compactMap { item in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + item.name)
            do {
                try item.data.write(to: tempURL, options: .atomic)
                return UploadPayload(fileURL: tempURL, fileName: item.name, totalBytes: item.data.count, isTemporary: true)
            } catch {
                return nil
            }
        }
        enqueue(driveId: driveId, directoryId: directoryId, files: payloads, onDone: onDone)
    }

    private func uploadSingleFile(taskId: UUID, driveId: Int, directoryId: Int, payload: UploadPayload) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].status = .inProgress(progress: 0.15)

        let mimeType = UTType(filenameExtension: (payload.fileName as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        defer {
            if payload.isTemporary {
                try? FileManager.default.removeItem(at: payload.fileURL)
            }
        }

        do {
            tasks[index].status = .inProgress(progress: 0.5)
            try await service.uploadFile(
                driveId: driveId,
                directoryId: directoryId,
                fileURL: payload.fileURL,
                fileName: payload.fileName,
                totalSize: payload.totalBytes,
                mimeType: mimeType
            )
            tasks[index].status = .completed
        } catch {
            let desc = (error as? APIError)?.errorDescription ?? error.localizedDescription
            tasks[index].status = .failed(message: desc)
        }
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
            if activeTasksCount == 0 {
                withAnimation(.snappy(duration: 0.3)) {
                    isPillVisible = false
                }
            }
        }
    }
}
