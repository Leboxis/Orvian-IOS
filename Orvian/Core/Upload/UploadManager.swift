import Foundation
import SwiftUI
import Observation
import UniformTypeIdentifiers

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
    let totalBytes: Int
    var status: UploadStatus
    let date: Date

    init(fileName: String, totalBytes: Int) {
        self.id = UUID()
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.status = .queued
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
