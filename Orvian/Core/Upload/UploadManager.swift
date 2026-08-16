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

    /// Enfile et exécute une liste de fichiers à uploader.
    func enqueue(driveId: Int, directoryId: Int, files: [(data: Data, name: String)], onDone: (() -> Void)? = nil) {
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let newTasks = files.map { UploadTaskItem(fileName: $0.name, totalBytes: $0.data.count) }
        tasks.append(contentsOf: newTasks)

        Task {
            for (index, file) in files.enumerated() {
                let taskId = newTasks[index].id
                await uploadSingleFile(
                    taskId: taskId,
                    driveId: driveId,
                    directoryId: directoryId,
                    data: file.data,
                    name: file.name
                )
            }

            onDone?()
            schedulePillAutoDismiss()
        }
    }

    private func uploadSingleFile(taskId: UUID, driveId: Int, directoryId: Int, data: Data, name: String) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].status = .inProgress(progress: 0.15)

        let mimeType = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        do {
            tasks[index].status = .inProgress(progress: 0.6)
            try await service.upload(
                driveId: driveId,
                directoryId: directoryId,
                data: data,
                fileName: name,
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
