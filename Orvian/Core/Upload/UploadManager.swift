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

/// Filtre thread-safe des rappels de progression : coalesce les ticks (un
/// upload chunked peut en produire des milliers) et garantit une progression
/// monotone. Sans lui, chaque tick engendrait une `Task` indépendante et deux
/// ticks pouvaient s'appliquer dans le désordre (barre qui recule).
private final class UploadProgressFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported = 0.0
    /// Pas minimal entre deux mises à jour d'interface (~1 % de la barre).
    private let step = 0.01

    /// Retourne true si ce tick doit être poussé vers l'interface.
    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction > lastReported + step || fraction >= 1 else { return false }
        if fraction > lastReported {
            lastReported = fraction
        }
        return true
    }
}

/// Sémaphore async borné : au plus `permits` uploads réseau simultanés.
/// Chaque tâche d'upload est une `Task` indépendante (annulable/suspendable
/// une par une) au lieu d'un groupe partagé où l'annulation touchait tout.
private actor UploadGate {
    private var permits: Int
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(_ permits: Int) {
        self.permits = permits
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }
        // `release` a déjà retiré l'entrée avant de reprendre ; ce retrait
        // ne sert qu'en cas de réveil sans `release` (jamais en pratique).
        waiters.removeValue(forKey: id)
    }

    func release() {
        if let key = waiters.keys.first, let continuation = waiters.removeValue(forKey: key) {
            continuation.resume()
        } else {
            permits += 1
        }
    }
}

/// Tâche d'upload individuelle.
struct UploadTaskItem: Identifiable, Equatable {
    let id: UUID
    var fileName: String
    var totalBytes: Int
    var status: UploadStatus
    let date: Date
    /// Contexte serveur (conservé pour relancer après pause/échec).
    var driveId: Int = 0
    var directoryId: Int = 0
    /// Fichier local prêt à envoyer (copie temporaire). `nil` pendant la
    /// préparation : seule l'annulation est alors possible, pas la pause.
    var localFileURL: URL? = nil
    /// URL d'origine du sélecteur de documents (re-copie possible si le
    /// temporaire a expiré). Les photos PhotosPicker n'en ont pas : leur
    /// réimport passe par une nouvelle sélection.
    var sourceDocumentURL: URL? = nil
    /// Octets réseau déjà envoyés (hors les 20 % de préparation locale).
    var uploadedBytes: Int = 0
    /// Débit lissé (octets/s) et temps restant estimé, calculés sur les ticks.
    var speedBytesPerSec: Double = 0
    var etaSeconds: Double? = nil
    /// Pause coopérative : le réseau est annulé mais le temporaire est gardé
    /// pour une reprise (`resumeTask`).
    var isPaused: Bool = false
    /// Une photo PhotosPicker dont l'item source est encore retenu peut être
    /// re-préparée après un échec de lecture (`retryTask`).
    var canReprepare: Bool = false

    init(
        id: UUID = UUID(),
        fileName: String,
        totalBytes: Int,
        status: UploadStatus = .queued,
        date: Date = Date(),
        driveId: Int = 0,
        directoryId: Int = 0,
        sourceDocumentURL: URL? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.status = status
        self.date = date
        self.driveId = driveId
        self.directoryId = directoryId
        self.sourceDocumentURL = sourceDocumentURL
    }

    /// Active sur le réseau (ni terminée, ni en pause).
    var isActive: Bool {
        guard !isPaused else { return false }
        switch status {
        case .queued, .inProgress: return true
        case .completed, .failed: return false
        }
    }

    /// La pause n'a de sens qu'une fois le fichier local prêt (la reprise
    /// réutilise le temporaire au lieu de recommencer la préparation).
    var canPause: Bool {
        !isPaused && localFileURL != nil && isActive
    }

    var canResume: Bool { isPaused }

    var canCancel: Bool { isActive || isPaused }

    /// Rejouable : le temporaire est encore là, la source document permet de
    /// le reconstruire, ou l'item PhotosPicker permet de recommencer la
    /// préparation. Une photo sans source retenue n'est pas rejouable
    /// (nouvelle sélection requise).
    var canRetry: Bool {
        if case .failed = status {
            return localFileURL != nil || sourceDocumentURL != nil || canReprepare
        }
        return false
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

/// Échantillon de débit par tâche : dernier volume daté + moyenne lissée.
private struct UploadSpeedState {
    var lastBytes: Int
    var lastTime: Date
    var smoothedBytesPerSec: Double
}

/// Suivi d'un lot (`enqueuePhotos`/`enqueueDocuments`) : `onDone` n'est
/// rappelée qu'une fois toutes les tâches du lot soldées (pause exclue : une
/// tâche en pause reste due jusqu'à sa reprise ou son annulation).
private struct UploadBatchState {
    var remaining: Int
    var results: [DriveFile]
    var onDone: (([DriveFile]) -> Void)?
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
    /// Un handler par tâche (et non plus par lot) : annuler/suspendre l'une
    /// ne touche pas les autres. Les lots ne servent qu'au `onDone`.
    private var taskHandlers: [UUID: Task<Void, Never>] = [:]
    /// Génération anti-course : l'épilogue d'un handler annulé ne doit pas
    /// retirer le mapping du handler de reprise lancé juste après.
    private var taskGenerations: [UUID: Int] = [:]
    private var batches: [UUID: UploadBatchState] = [:]
    /// Lot et rappel d'origine de chaque tâche (pour `retryTask`, qui rouvre
    /// un mini-lot avec le même `onDone` afin que la grille se rafraîchisse).
    private var taskBatches: [UUID: UUID] = [:]
    private var taskCompletions: [UUID: (([DriveFile]) -> Void)?] = [:]
    /// Items PhotosPicker en attente de préparation (phase courte avant la
    /// copie temporaire ; libérés dès le temporaire prêt).
    private var photoSources: [UUID: (item: PhotosPickerItem, index: Int)] = [:]
    private var speedStates: [UUID: UploadSpeedState] = [:]
    /// L'API kDrive traite chaque upload de manière indépendante (session
    /// dédiée aux gros fichiers), plusieurs fichiers peuvent donc partir en
    /// parallèle sans verrou côté serveur.
    private let gate = UploadGate(4)

    private init() {}

    var activeTasksCount: Int {
        tasks.filter(\.isActive).count
    }

    var pausedTasksCount: Int {
        tasks.filter { $0.isPaused }.count
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

    // MARK: - Débit & temps restant

    /// Octets réseau déjà envoyés sur l'ensemble des tâches visibles.
    var overallUploadedBytes: Int {
        tasks.reduce(0) { $0 + $1.uploadedBytes }
    }

    var overallTotalBytes: Int {
        tasks.reduce(0) { $0 + max($1.totalBytes, $1.uploadedBytes) }
    }

    /// Somme des débits des tâches réellement en train d'émettre.
    var overallSpeedBytesPerSec: Double {
        tasks.reduce(0.0) { $0 + ($1.isActive ? $1.speedBytesPerSec : 0) }
    }

    var overallETASeconds: Double? {
        let speed = overallSpeedBytesPerSec
        guard speed > 512 else { return nil }
        let remaining = overallTotalBytes - overallUploadedBytes
        guard remaining > 0 else { return nil }
        return Double(remaining) / speed
    }

    var overallSpeedText: String { Self.speedText(overallSpeedBytesPerSec) }

    var overallETAText: String { Self.etaText(overallETASeconds) }

    /// 4 200 000 → « 4,2 Mo/s » (locale courante), 0 → « » (rien à afficher).
    static func speedText(_ bytesPerSec: Double) -> String {
        guard bytesPerSec >= 500 else { return "" }
        if bytesPerSec >= 1_000_000 {
            return String(format: "%.1f Mo/s", locale: Locale.current, bytesPerSec / 1_000_000)
        }
        return String(format: "%.0f Ko/s", locale: Locale.current, bytesPerSec / 1_000)
    }

    /// 42 → « 0:42 », 750 → « 12:30 », 4000 → « 1:06:40 », inconnu → « ».
    static func etaText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - File d'uploads

    /// Import immédiat et asynchrone des photos/vidéos depuis PhotosPicker (la bulle s'affiche instantanément)
    func enqueuePhotos(driveId: Int, directoryId: Int, items: [PhotosPickerItem], onDone: (([DriveFile]) -> Void)? = nil) {
        guard !items.isEmpty else { return }
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let batchId = UUID()
        batches[batchId] = UploadBatchState(remaining: items.count, results: [], onDone: onDone)
        for (index, item) in items.enumerated() {
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let name = items.count == 1 ? "Photo.\(ext)" : "Média \(index + 1).\(ext)"
            var task = UploadTaskItem(
                fileName: name,
                totalBytes: 0,
                status: .inProgress(progress: 0.05),
                driveId: driveId,
                directoryId: directoryId
            )
            task.canReprepare = true
            tasks.append(task)
            photoSources[task.id] = (item: item, index: index)
            taskBatches[task.id] = batchId
            taskCompletions[task.id] = onDone
            launch(taskId: task.id)
        }
    }

    /// Import immédiat et asynchrone des documents (la bulle s'affiche instantanément)
    func enqueueDocuments(driveId: Int, directoryId: Int, urls: [URL], onDone: (([DriveFile]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        hidePillTask?.cancel()
        hidePillTask = nil
        isPillVisible = true

        let batchId = UUID()
        batches[batchId] = UploadBatchState(remaining: urls.count, results: [], onDone: onDone)
        for url in urls {
            let task = UploadTaskItem(
                fileName: url.lastPathComponent,
                totalBytes: 0,
                status: .inProgress(progress: 0.05),
                driveId: driveId,
                directoryId: directoryId,
                sourceDocumentURL: url
            )
            tasks.append(task)
            taskBatches[task.id] = batchId
            taskCompletions[task.id] = onDone
            launch(taskId: task.id)
        }
    }

    /// Démarre (ou redémarre après reprise) le handler d'une tâche.
    private func launch(taskId: UUID) {
        taskHandlers[taskId]?.cancel()
        let generation = (taskGenerations[taskId] ?? 0) + 1
        taskGenerations[taskId] = generation
        taskHandlers[taskId] = Task { [weak self] in
            guard let self else { return }
            await self.execute(taskId: taskId)
            // Seul le handler courant nettoie : un ancien handler annulé qui
            // se termine après une reprise ne touche pas au nouveau mapping.
            if self.taskGenerations[taskId] == generation {
                self.taskHandlers.removeValue(forKey: taskId)
                self.taskGenerations.removeValue(forKey: taskId)
            }
        }
    }

    /// Corps d'une tâche : attente d'un slot réseau puis préparation et envoi.
    /// Les sorties « pause » ne soldent pas le lot (la reprise relance un
    /// handler) ; toutes les autres sorties terminales le soldent.
    private func execute(taskId: UUID) async {
        // Annulée avant même de démarrer (ex. « tout annuler » juste après
        // l'ajout) : le responsable du retrait a déjà soldé le lot.
        guard !Task.isCancelled, tasks.contains(where: { $0.id == taskId }) else { return }
        if tasks.first(where: { $0.id == taskId })?.isPaused == true { return }
        await gate.acquire()
        await runGated(taskId: taskId)
        await gate.release()
    }

    private func runGated(taskId: UUID) async {
        guard !Task.isCancelled, let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        if tasks[index].isPaused { return }
        let driveId = tasks[index].driveId
        let directoryId = tasks[index].directoryId

        // 1) Préparation du fichier local (sautée si la reprise dispose déjà
        // du temporaire).
        if tasks[index].localFileURL == nil {
            let prepared: UploadPayload?
            if photoSources[taskId] != nil {
                prepared = await preparePhoto(taskId: taskId)
            } else {
                prepared = await prepareDocument(taskId: taskId)
            }
            guard !Task.isCancelled, let current = tasks.firstIndex(where: { $0.id == taskId }) else { return }
            // Mise en pause pendant la préparation : on garde le fichier
            // obtenu pour la reprise et on sort sans solder le lot.
            if tasks[current].isPaused {
                if let payload = prepared {
                    tasks[current].localFileURL = payload.fileURL
                    tasks[current].totalBytes = payload.totalBytes
                    tasks[current].fileName = payload.fileName
                }
                return
            }
            guard let payload else {
                // Échec de préparation : le statut `.failed` est déjà posé
                // par `preparePhoto`/`prepareDocument`, on solde ici.
                // Annulation en revanche : la tâche a été retirée et le lot
                // déjà soldé par l'auteur du retrait — ne pas re-solder.
                if tasks.contains(where: { $0.id == taskId }) {
                    finishTask(taskId: taskId, result: nil)
                }
                return
            }
            photoSources.removeValue(forKey: taskId)
            tasks[current].localFileURL = payload.fileURL
            tasks[current].totalBytes = payload.totalBytes
            tasks[current].fileName = payload.fileName
            tasks[current].canReprepare = false
            tasks[current].status = .inProgress(progress: 0.2)
        } else if let url = tasks[index].localFileURL,
                  !FileManager.default.fileExists(atPath: url.path) {
            // Temporaire purgé par le système entre-temps : on retente depuis
            // la source document si possible, sinon échec explicite.
            tasks[index].localFileURL = nil
            if tasks[index].sourceDocumentURL != nil {
                guard let payload = await prepareDocument(taskId: taskId) else {
                    // Même garde anti double-solde que ci-dessus.
                    if tasks.contains(where: { $0.id == taskId }) {
                        finishTask(taskId: taskId, result: nil)
                    }
                    return
                }
                guard let current = tasks.firstIndex(where: { $0.id == taskId }), !tasks[current].isPaused else { return }
                tasks[current].localFileURL = payload.fileURL
                tasks[current].totalBytes = payload.totalBytes
                tasks[current].status = .inProgress(progress: 0.2)
            } else {
                tasks[index].status = .failed(message: "Fichier temporaire expiré — réimportez le média.")
                finishTask(taskId: taskId, result: nil)
                return
            }
        }

        // 2) Envoi réseau.
        guard let current = tasks.firstIndex(where: { $0.id == taskId }),
              let fileURL = tasks[current].localFileURL
        else { return }
        let payload = UploadPayload(
            fileURL: fileURL,
            fileName: tasks[current].fileName,
            totalBytes: tasks[current].totalBytes,
            isTemporary: true
        )
        let result = await uploadSingleFile(taskId: taskId, driveId: driveId, directoryId: directoryId, payload: payload)
        // Tâche retirée entre-temps (annulation) ou mise en pause : le lot a
        // déjà été soldé par l'annulation, ou reste dû pour la reprise.
        guard tasks.contains(where: { $0.id == taskId }) else { return }
        if tasks.first(where: { $0.id == taskId })?.isPaused == true { return }
        finishTask(taskId: taskId, result: result)
    }

    /// Prépare (I/O disque) un média PhotosPicker.
    private func preparePhoto(taskId: UUID) async -> UploadPayload? {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }),
              let source = photoSources[taskId]
        else { return nil }
        let item = source.item
        let itemIndex = source.index

        let contentType = item.supportedContentTypes.first ?? .data
        let ext = contentType.preferredFilenameExtension ?? "jpg"
        let realName = "Import-\(Int(Date().timeIntervalSince1970))-\(itemIndex + 1).\(ext)"

        tasks[index].fileName = realName
        tasks[index].status = .inProgress(progress: 0.15)

        var payload: UploadPayload? = nil
        if let picked = try? await item.loadTransferable(type: PickedPhotoTransferable.self) {
            payload = await UploadFileIO.payload(forTemporaryURL: picked.url, fileName: realName)
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            payload = await UploadFileIO.writeToTemporaryDirectory(data: data, fileName: realName)
        }

        guard let payload else {
            if !Task.isCancelled,
               let current = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[current].status = .failed(message: "Échec de lecture du média")
            }
            return nil
        }

        if let current = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[current].fileName = realName
            tasks[current].totalBytes = payload.totalBytes
            tasks[current].status = .inProgress(progress: 0.2)
        }
        return payload
    }

    /// Prépare (copie temporaire) un document du sélecteur de fichiers.
    private func prepareDocument(taskId: UUID) async -> UploadPayload? {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }),
              let sourceURL = tasks[index].sourceDocumentURL
        else { return nil }
        tasks[index].status = .inProgress(progress: 0.15)

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let payload = await UploadFileIO.copyToTemporaryDirectory(sourceURL: sourceURL, fileName: tasks[index].fileName)

        guard let payload else {
            if !Task.isCancelled,
               let current = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[current].status = .failed(message: "Échec de copie du fichier")
            }
            return nil
        }

        if let current = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[current].totalBytes = payload.totalBytes
            tasks[current].status = .inProgress(progress: 0.2)
        }
        return payload
    }

    private func uploadSingleFile(taskId: UUID, driveId: Int, directoryId: Int, payload: UploadPayload) async -> DriveFile? {
        guard !Task.isCancelled else {
            // Entrée annulée avant démarrage : le temporaire appartient à la
            // tâche (reprise éventuelle) ou à l'auteur du retrait qui le
            // nettoie — ici on ne touche à rien pour éviter de supprimer le
            // fichier d'un handler de reprise lancé entre-temps.
            return nil
        }
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            if payload.isTemporary {
                await UploadFileIO.removeTemporaryFile(payload.fileURL)
            }
            return nil
        }
        tasks[index].status = .inProgress(progress: 0.15)

        var result: DriveFile?
        do {
            tasks[index].status = .inProgress(progress: 0.2)
            speedStates[taskId] = UploadSpeedState(lastBytes: 0, lastTime: Date(), smoothedBytesPerSec: 0)
            let progressFilter = UploadProgressFilter()
            let uploadedFile = try await service.uploadFile(
                driveId: driveId,
                directoryId: directoryId,
                fileURL: payload.fileURL,
                fileName: payload.fileName,
                totalSize: payload.totalBytes,
                progress: { [weak self] fraction in
                    guard progressFilter.shouldReport(fraction) else { return }
                    Task { @MainActor in
                        guard let self,
                              let currentIndex = self.tasks.firstIndex(where: { $0.id == taskId })
                        else { return }
                        guard case .inProgress = self.tasks[currentIndex].status,
                              !self.tasks[currentIndex].isPaused
                        else { return }
                        // Les 20 premiers pourcents représentent la préparation
                        // locale ; les 80 suivants correspondent aux octets envoyés.
                        self.noteProgress(taskId: taskId, index: currentIndex, fraction: fraction)
                        self.tasks[currentIndex].status = .inProgress(progress: 0.2 + fraction * 0.8)
                    }
                }
            )
            try Task.checkCancellation()
            guard let currentIndex = tasks.firstIndex(where: { $0.id == taskId }) else {
                throw CancellationError()
            }
            tasks[currentIndex].status = .completed
            tasks[currentIndex].uploadedBytes = tasks[currentIndex].totalBytes
            tasks[currentIndex].speedBytesPerSec = 0
            tasks[currentIndex].etaSeconds = nil
            tasks[currentIndex].localFileURL = nil
            speedStates.removeValue(forKey: taskId)
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
            if Task.isCancelled {
                // Pause : on garde le temporaire pour la reprise et on fige
                // le débit ; sinon (annulation) le responsable du retrait
                // nettoie le fichier.
                if let currentIndex = tasks.firstIndex(where: { $0.id == taskId }),
                   tasks[currentIndex].isPaused {
                    tasks[currentIndex].speedBytesPerSec = 0
                    tasks[currentIndex].etaSeconds = nil
                    speedStates.removeValue(forKey: taskId)
                } else if tasks.firstIndex(where: { $0.id == taskId }) == nil, payload.isTemporary {
                    await UploadFileIO.removeTemporaryFile(payload.fileURL)
                }
            } else if let currentIndex = tasks.firstIndex(where: { $0.id == taskId }) {
                let desc = (error as? APIError)?.errorDescription ?? error.localizedDescription
                tasks[currentIndex].status = .failed(message: desc)
                tasks[currentIndex].speedBytesPerSec = 0
                tasks[currentIndex].etaSeconds = nil
                speedStates.removeValue(forKey: taskId)
                // Temporaire conservé pour `retryTask`.
            }
        }

        // Succès : le temporaire est supprimé ; pause/échec : conservé.
        if result != nil, payload.isTemporary {
            await UploadFileIO.removeTemporaryFile(payload.fileURL)
        }
        return result
    }

    /// Met à jour octets envoyés, débit lissé et ETA d'une tâche.
    private func noteProgress(taskId: UUID, index: Int, fraction: Double) {
        let total = max(tasks[index].totalBytes, 1)
        let bytes = Int((fraction * Double(total)).rounded())
        let now = Date()
        tasks[index].uploadedBytes = bytes
        if var state = speedStates[taskId] {
            let elapsed = now.timeIntervalSince(state.lastTime)
            if elapsed >= 0.25 {
                let delta = bytes - state.lastBytes
                if elapsed > 0, delta >= 0 {
                    let instant = Double(delta) / elapsed
                    state.smoothedBytesPerSec = state.smoothedBytesPerSec <= 0
                        ? instant
                        : 0.35 * instant + 0.65 * state.smoothedBytesPerSec
                }
                state.lastBytes = bytes
                state.lastTime = now
                speedStates[taskId] = state
            }
        } else {
            speedStates[taskId] = UploadSpeedState(lastBytes: bytes, lastTime: now, smoothedBytesPerSec: 0)
        }
        let speed = speedStates[taskId]?.smoothedBytesPerSec ?? 0
        tasks[index].speedBytesPerSec = speed
        if speed > 512, tasks[index].totalBytes > bytes {
            tasks[index].etaSeconds = Double(tasks[index].totalBytes - bytes) / speed
        } else {
            tasks[index].etaSeconds = nil
        }
    }

    // MARK: - Contrôles par tâche

    /// Suspend l'envoi en gardant le fichier local pour une reprise.
    /// Sans effet pendant la préparation (seule l'annulation est offerte).
    func pauseTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].canPause
        else { return }
        tasks[index].isPaused = true
        tasks[index].speedBytesPerSec = 0
        tasks[index].etaSeconds = nil
        speedStates.removeValue(forKey: id)
        taskHandlers[id]?.cancel()
    }

    /// Reprend une tâche en pause (réutilise le temporaire conservé).
    func resumeTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].isPaused
        else { return }
        switch tasks[index].status {
        case .queued, .inProgress: break
        case .completed, .failed: return
        }
        tasks[index].isPaused = false
        launch(taskId: id)
    }

    /// Annule l'envoi et retire la tâche (le temporaire est supprimé).
    func cancelTask(_ id: UUID) {
        taskHandlers[id]?.cancel()
        taskHandlers.removeValue(forKey: id)
        speedStates.removeValue(forKey: id)
        photoSources.removeValue(forKey: id)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let wasPending = tasks[index].isActive || tasks[index].isPaused
        let fileURL = tasks[index].localFileURL
        tasks.remove(at: index)
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if wasPending {
            finishTask(taskId: id, result: nil)
        } else {
            taskBatches.removeValue(forKey: id)
        }
        // Le rappel d'origine survit à la fin du lot : `retryTask` en a
        // besoin pour rafraîchir la grille après une relance réussie. Il
        // n'est libéré qu'au retrait définitif de la tâche.
        taskCompletions.removeValue(forKey: id)
        if tasks.isEmpty {
            isPillVisible = false
        }
    }

    /// Relance une tâche en échec (temporaire conservé ou source à recopier).
    func retryTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].canRetry
        else { return }
        if let url = tasks[index].localFileURL,
           !FileManager.default.fileExists(atPath: url.path) {
            tasks[index].localFileURL = nil
        }
        guard tasks[index].localFileURL != nil
            || tasks[index].sourceDocumentURL != nil
            || photoSources[id] != nil
        else { return }
        tasks[index].isPaused = false
        tasks[index].uploadedBytes = 0
        tasks[index].speedBytesPerSec = 0
        tasks[index].etaSeconds = nil
        tasks[index].status = .inProgress(progress: tasks[index].localFileURL != nil ? 0.2 : 0.05)
        // Nouveau mini-lot avec le rappel d'origine pour rafraîchir la grille.
        let batchId = UUID()
        batches[batchId] = UploadBatchState(remaining: 1, results: [], onDone: taskCompletions[id] ?? nil)
        taskBatches[id] = batchId
        launch(taskId: id)
    }

    /// Retire une tâche terminée ou en échec de la liste (sans relance).
    func removeTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        switch tasks[index].status {
        case .completed, .failed: break
        case .queued, .inProgress: return
        }
        if let fileURL = tasks[index].localFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        photoSources.removeValue(forKey: id)
        speedStates.removeValue(forKey: id)
        taskBatches.removeValue(forKey: id)
        taskCompletions.removeValue(forKey: id)
        tasks.remove(at: index)
        if tasks.isEmpty {
            isPillVisible = false
        }
    }

    func pauseAll() {
        for task in tasks where task.canPause {
            pauseTask(task.id)
        }
    }

    func resumeAll() {
        for task in tasks where task.canResume {
            resumeTask(task.id)
        }
    }

    /// Annule tous les envois actifs ou en pause, garde l'historique soldé.
    func cancelAllActive() {
        for task in tasks where task.canCancel {
            cancelTask(task.id)
        }
    }

    /// Solde une tâche vis-à-vis de son lot et déclenche `onDone` au dernier.
    /// Le rappel d'origine (`taskCompletions`) survit : un `retryTask`
    /// ultérieur rouvre un mini-lot avec ce même rappel.
    private func finishTask(taskId: UUID, result: DriveFile?) {
        guard let batchId = taskBatches.removeValue(forKey: taskId),
              var batch = batches[batchId]
        else {
            return
        }
        batch.remaining -= 1
        if let result {
            batch.results.append(result)
        }
        if batch.remaining <= 0 {
            batches.removeValue(forKey: batchId)
            let done = batch.results
            let callback = batch.onDone
            callback?(done)
            schedulePillAutoDismiss()
        } else {
            batches[batchId] = batch
        }
    }

    /// Utilisé à la déconnexion : aucune tâche d'un ancien compte ne doit
    /// continuer ni rester visible dans la session suivante.
    func cancelAllAndClear() {
        hidePillTask?.cancel()
        hidePillTask = nil
        for handler in taskHandlers.values {
            handler.cancel()
        }
        taskHandlers.removeAll()
        taskGenerations.removeAll()
        for task in tasks {
            if let fileURL = task.localFileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        batches.removeAll()
        taskBatches.removeAll()
        taskCompletions.removeAll()
        photoSources.removeAll()
        speedStates.removeAll()
        tasks.removeAll()
        isPillVisible = false
    }

    func clearCompleted() {
        var removedURLs: [URL] = []
        tasks.removeAll {
            switch $0.status {
            case .completed, .failed:
                if let fileURL = $0.localFileURL {
                    removedURLs.append(fileURL)
                }
                photoSources.removeValue(forKey: $0.id)
                speedStates.removeValue(forKey: $0.id)
                taskBatches.removeValue(forKey: $0.id)
                taskCompletions.removeValue(forKey: $0.id)
                return true
            case .queued, .inProgress:
                return false
            }
        }
        for url in removedURLs {
            try? FileManager.default.removeItem(at: url)
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
            // Une pause en attente n'est pas une fin : la bulle reste visible
            // pour reprendre ou annuler.
            if activeTasksCount == 0 && pausedTasksCount == 0 && !hasFailures {
                withAnimation(.snappy(duration: 0.3)) {
                    isPillVisible = false
                }
            }
        }
    }
}
