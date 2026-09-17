import SwiftUI
import UIKit

/// Service de téléchargement et d'export/partage de fichiers kDrive.
@MainActor
final class FileDownloadService: ObservableObject {
    static let shared = FileDownloadService()

    @Published var isDownloading = false
    /// Progression du téléchargement courant (0…1) ; reste à 0 tant que le
    /// serveur n'annonce pas de taille totale (progression indéterminée).
    @Published var progress: Double = 0
    @Published var downloadingFileName: String?
    @Published var errorMessage: String?

    private var downloadTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var presentationAllowed = false
    private weak var presentationWindow: UIWindow?
    private weak var activityController: UIActivityViewController?
    private var sharedDirectory: URL?
    private struct PendingShare {
        let fileURL: URL
        let directory: URL
        let credential: String
    }
    private var pendingShare: PendingShare?
    private let currentCredential: () -> String?

    init(currentCredential: @escaping () -> String? = { TokenStore.credentialFingerprint() }) {
        self.currentCredential = currentCredential
    }

    /// Transfère la propriété du fichier terminé à la file de partage.
    func enqueueCompletedDownload(fileURL: URL, directory: URL, credential: String) {
        pendingShare = PendingShare(fileURL: fileURL, directory: directory, credential: credential)
        presentPendingShareIfAllowed()
    }

    /// La fenêtre de contenu est fournie par le coordinateur de confidentialité,
    /// jamais recherchée parmi les fenêtres clés (qui peuvent être le verrou).
    func updatePresentation(isAllowed: Bool, window: UIWindow?) {
        presentationAllowed = isAllowed
        presentationWindow = window
        presentPendingShareIfAllowed()
    }

    /// Point d'entrée conservé `async` pour les appelants existants ; le
    /// travail est porté par une tâche interne qui reste annulable via
    /// `cancelDownload()`.
    func downloadAndShare(driveId: Int, file: DriveFile) async {
        guard !file.isDirectory else { return }
        guard !isDownloading, pendingShare == nil, activityController == nil else {
            errorMessage = "Un autre téléchargement est déjà en cours."
            return
        }
        isDownloading = true
        progress = 0
        downloadingFileName = file.name
        errorMessage = nil
        guard let credential = currentCredential() else {
            isDownloading = false
            downloadingFileName = nil
            return
        }
        let generation = sessionGeneration
        let task = Task {
            await performDownloadAndShare(driveId: driveId, file: file, credential: credential, generation: generation)
        }
        downloadTask = task
        await task.value
    }

    /// Annule le téléchargement en cours : les fichiers temporaires sont
    /// nettoyés et aucun message d'erreur n'est présenté.
    func cancelDownload() {
        downloadTask?.cancel()
        if let pendingShare {
            try? FileManager.default.removeItem(at: pendingShare.directory)
            self.pendingShare = nil
        }
    }

    func cancelAllAndClear() {
        sessionGeneration &+= 1
        cancelDownload()
        downloadTask = nil
        isDownloading = false
        progress = 0
        downloadingFileName = nil
        activityController?.dismiss(animated: false)
        activityController = nil
        if let sharedDirectory {
            try? FileManager.default.removeItem(at: sharedDirectory)
            self.sharedDirectory = nil
        }
        errorMessage = nil
    }

    private func performDownloadAndShare(driveId: Int, file: DriveFile, credential: String, generation: Int) async {
        defer {
            if generation == sessionGeneration {
                isDownloading = false
                progress = 0
                downloadingFileName = nil
                downloadTask = nil
            }
        }

        var temporaryURLToClean: URL?
        var directoryToClean: URL?
        do {
            try Task.checkCancellation()
            guard generation == sessionGeneration,
                  credential == currentCredential() else { throw CancellationError() }
            guard let remoteURL = await MediaURLCache.shared.url(driveId: driveId, fileId: file.id) else {
                throw FileDownloadError.missingTemporaryURL
            }
            try Task.checkCancellation()

            let tempURL = try await download(
                from: remoteURL,
                driveId: driveId,
                fileId: file.id,
                mayRefreshURL: true
            )
            temporaryURLToClean = tempURL
            try Task.checkCancellation()
            guard generation == sessionGeneration,
                  credential == currentCredential() else { throw CancellationError() }

            let downloadDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrvianDownloads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            directoryToClean = downloadDirectory
            let destinationURL = downloadDirectory.appendingPathComponent(safeFileName(for: file), isDirectory: false)

            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            temporaryURLToClean = nil

            // La file d'attente conserve le fichier jusqu'au déverrouillage.
            directoryToClean = nil
            enqueueCompletedDownload(fileURL: destinationURL, directory: downloadDirectory, credential: credential)
        } catch {
            if let temporaryURLToClean {
                try? FileManager.default.removeItem(at: temporaryURLToClean)
            }
            if let directoryToClean {
                try? FileManager.default.removeItem(at: directoryToClean)
            }
            // Annulation explicite : ce n'est pas un échec, aucun message.
            guard !Task.isCancelled, generation == sessionGeneration,
                  credential == currentCredential() else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Vérifie explicitement le statut HTTP. `URLSession` considère
    /// aussi une page 403/404 comme un téléchargement réussi et fournit alors
    /// son corps HTML dans un fichier temporaire.
    private func download(
        from remoteURL: URL,
        driveId: Int,
        fileId: Int,
        mayRefreshURL: Bool
    ) async throws -> URL {
        guard remoteURL.scheme?.lowercased() == "https", remoteURL.host != nil else {
            throw FileDownloadError.invalidURL
        }

        let (temporaryURL, response) = try await downloadWithProgress(from: remoteURL)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw FileDownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            let refreshableStatuses = [401, 403, 404, 410]
            if mayRefreshURL,
               refreshableStatuses.contains(http.statusCode),
               let freshURL = await MediaURLCache.shared.freshURL(driveId: driveId, fileId: fileId) {
                return try await download(
                    from: freshURL,
                    driveId: driveId,
                    fileId: fileId,
                    mayRefreshURL: false
                )
            }
            throw FileDownloadError.http(status: http.statusCode)
        }
        return temporaryURL
    }

    /// Téléchargement délégué : la progression réelle remonte via le délégué
    /// (l'API `URLSession.download(from:)` async n'en fournit aucune) et
    /// l'annulation suspend la tâche de téléchargement elle-même. Comme pour
    /// les uploads, la tâche est créée avant le handler d'annulation : une
    /// Task Swift déjà annulée ne peut plus invalider la session avant la
    /// création de la tâche.
    private func downloadWithProgress(from remoteURL: URL) async throws -> (URL, URLResponse) {
        let generation = sessionGeneration
        let delegate = DownloadProgressDelegate(progress: { [weak self] fraction in
            Task { @MainActor in
                guard self?.sessionGeneration == generation, self?.isDownloading == true else { return }
                self?.progress = fraction
            }
        })
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: delegateQueue)
        defer { session.finishTasksAndInvalidate() }

        let downloadTask = session.downloadTask(with: remoteURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.completion.install(continuation)
                downloadTask.resume()
            }
        } onCancel: {
            downloadTask.cancel()
        }
    }
    /// Le nom vient du serveur. Il ne doit jamais pouvoir créer un chemin
    /// relatif (`..`) ou un sous-dossier dans le répertoire temporaire.
    private func safeFileName(for file: DriveFile) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        let components = file.name.components(separatedBy: forbidden)
        let sanitized = components
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            return "Fichier-\(file.id)"
        }

        // APFS limite un composant de chemin à 255 octets. Garder une marge
        // et l'extension évite qu'un nom serveur très long fasse échouer le
        // déplacement du fichier pourtant téléchargé avec succès.
        let maximumNameBytes = 200
        guard sanitized.utf8.count > maximumNameBytes else { return sanitized }
        let pathExtension = (sanitized as NSString).pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(truncate(pathExtension, toUTF8Bytes: 24))"
        let stem = (sanitized as NSString).deletingPathExtension
        let shortenedStem = truncate(stem, toUTF8Bytes: maximumNameBytes - suffix.utf8.count)
        return shortenedStem.isEmpty ? "Fichier-\(file.id)\(suffix)" : shortenedStem + suffix
    }

    private func truncate(_ value: String, toUTF8Bytes maximumBytes: Int) -> String {
        var result = value
        while result.utf8.count > maximumBytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }

    /// Ouvre le menu de partage natif iOS (UIActivityViewController) : Enregistrer dans Fichiers, Enregistrer l'image/vidéo, AirDrop, etc.
    private func presentPendingShareIfAllowed() {
        guard let pendingShare else { return }
        guard pendingShare.credential == currentCredential() else {
            try? FileManager.default.removeItem(at: pendingShare.directory)
            self.pendingShare = nil
            return
        }
        guard presentationAllowed,
              presentationWindow?.windowScene?.activationState == .foregroundActive else { return }
        self.pendingShare = nil
        if !presentShareSheet(for: pendingShare.fileURL, cleanupDirectory: pendingShare.directory) {
            try? FileManager.default.removeItem(at: pendingShare.directory)
            errorMessage = FileDownloadError.cannotPresentShareSheet.localizedDescription
        }
    }

    @discardableResult
    private func presentShareSheet(for fileURL: URL, cleanupDirectory: URL) -> Bool {
        guard presentationAllowed,
              let rootVC = presentationWindow?.rootViewController else {
            return false
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            try? FileManager.default.removeItem(at: cleanupDirectory)
            Task { @MainActor in
                guard self?.sharedDirectory == cleanupDirectory else { return }
                self?.sharedDirectory = nil
                self?.activityController = nil
            }
        }
        activityController = activityVC
        sharedDirectory = cleanupDirectory
        topVC.present(activityVC, animated: true)
        return true
    }
}

/// Délégué isolé par téléchargement : remonte les octets reçus (coalescés à
/// ~1 % pour éviter un rendu SwiftUI par tick de URLSession) et résout la
/// continuation avec le fichier déplacé dans le répertoire temporaire de
/// l'app — le système supprime le sien au retour du callback. Un seul
/// callback par transfert réussit : `didFinishDownloadingTo` pour le succès,
/// `didCompleteWithError` pour tout échec (annulation comprise).
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    let completion = TransferCompletion<(URL, URLResponse)>()
    private var lastReported = 0.0

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        guard fraction > lastReported + 0.01 || fraction >= 1 else { return }
        lastReported = fraction
        progress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Le système supprime le fichier de `location` dès le retour de ce
        // callback : le déplacer de façon synchrone vers un fichier que l'on
        // contrôle évite que le `moveItem` de l'appelant s'exécute sur un
        // fichier déjà supprimé (« CFNetworkDownload_xxx.tmp couldn't be
        // moved… » atteint 100 % puis échoue).
        let safeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrvianDownload-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: safeURL)
            if let response = downloadTask.response {
                if !completion.finish(.success((safeURL, response))) {
                    try? FileManager.default.removeItem(at: safeURL)
                }
            } else {
                try? FileManager.default.removeItem(at: safeURL)
                completion.finish(.failure(APIError.invalidResponse))
            }
        } catch {
            completion.finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Le rendez-vous ignore ce rappel si le succès a déjà été livré.
        // Une annulation précoce reste mémorisée jusqu'à l'attente de l'appelant.
        completion.finish(.failure(error ?? APIError.invalidResponse))
    }
}

private enum FileDownloadError: LocalizedError {
    case missingTemporaryURL
    case invalidURL
    case invalidResponse
    case http(status: Int)
    case cannotPresentShareSheet

    var errorDescription: String? {
        switch self {
        case .missingTemporaryURL:
            return "Impossible d’obtenir le lien de téléchargement."
        case .invalidURL:
            return "Le lien de téléchargement est invalide."
        case .invalidResponse:
            return "Le serveur a renvoyé une réponse invalide."
        case let .http(status):
            return "Le fichier n’a pas été téléchargé (HTTP \(status))."
        case .cannotPresentShareSheet:
            return "La feuille de partage ne peut pas être affichée."
        }
    }
}
