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

    /// Point d'entrée conservé `async` pour les appelants existants ; le
    /// travail est porté par une tâche interne qui reste annulable via
    /// `cancelDownload()`.
    func downloadAndShare(driveId: Int, file: DriveFile) async {
        guard !file.isDirectory else { return }
        guard !isDownloading else {
            errorMessage = "Un autre téléchargement est déjà en cours."
            return
        }
        isDownloading = true
        progress = 0
        downloadingFileName = file.name
        errorMessage = nil
        let task = Task { await performDownloadAndShare(driveId: driveId, file: file) }
        downloadTask = task
        await task.value
    }

    /// Annule le téléchargement en cours : les fichiers temporaires sont
    /// nettoyés et aucun message d'erreur n'est présenté.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func performDownloadAndShare(driveId: Int, file: DriveFile) async {
        defer {
            isDownloading = false
            progress = 0
            downloadingFileName = nil
        }

        var temporaryURLToClean: URL?
        var directoryToClean: URL?
        do {
            guard let remoteURL = await MediaURLCache.shared.url(driveId: driveId, fileId: file.id) else {
                throw FileDownloadError.missingTemporaryURL
            }

            let tempURL = try await download(
                from: remoteURL,
                driveId: driveId,
                fileId: file.id,
                mayRefreshURL: true
            )
            temporaryURLToClean = tempURL

            let downloadDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrvianDownloads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            directoryToClean = downloadDirectory
            let destinationURL = downloadDirectory.appendingPathComponent(safeFileName(for: file), isDirectory: false)

            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            temporaryURLToClean = nil

            guard presentShareSheet(for: destinationURL, cleanupDirectory: downloadDirectory) else {
                throw FileDownloadError.cannotPresentShareSheet
            }
            // La feuille de partage prend désormais en charge le nettoyage.
            directoryToClean = nil
        } catch {
            if let temporaryURLToClean {
                try? FileManager.default.removeItem(at: temporaryURLToClean)
            }
            if let directoryToClean {
                try? FileManager.default.removeItem(at: directoryToClean)
            }
            // Annulation explicite : ce n'est pas un échec, aucun message.
            guard !Task.isCancelled else { return }
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
        let delegate = DownloadProgressDelegate(progress: { [weak self] fraction in
            Task { @MainActor in
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
                delegate.continuation = continuation
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
    @discardableResult
    private func presentShareSheet(for fileURL: URL, cleanupDirectory: URL) -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
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
        activityVC.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: cleanupDirectory)
        }
        topVC.present(activityVC, animated: true)
        return true
    }
}

/// Délégué isolé par téléchargement : remonte les octets reçus (coalescés à
/// ~1 % pour éviter un rendu SwiftUI par tick de URLSession) et résout la
/// continuation avec le fichier temporaire. Un seul callback par transfert
/// réussit : `didFinishDownloadingTo` pour le succès, `didCompleteWithError`
/// pour tout échec (annulation comprise).
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<(URL, URLResponse), Error>?
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
        guard let continuation else { return }
        self.continuation = nil
        if let response = downloadTask.response {
            continuation.resume(returning: (location, response))
        } else {
            continuation.resume(throwing: APIError.invalidResponse)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Succès déjà résolu par `didFinishDownloadingTo` (continuation nil) :
        // ce callback ne traite alors rien. Sinon, tout échec — annulation
        // comprise — reprend la continuation avec son erreur.
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error ?? APIError.invalidResponse)
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
