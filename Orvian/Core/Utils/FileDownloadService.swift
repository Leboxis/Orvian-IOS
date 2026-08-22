import SwiftUI
import UIKit

/// Service de téléchargement et d'export/partage de fichiers kDrive.
@MainActor
final class FileDownloadService: ObservableObject {
    static let shared = FileDownloadService()

    @Published var isDownloading = false
    @Published var errorMessage: String?

    /// Télécharge le fichier localement dans les fichiers temporaires puis affiche la feuille de partage native iOS.
    func downloadAndShare(driveId: Int, file: DriveFile) async {
        guard !file.isDirectory else { return }
        guard !isDownloading else {
            errorMessage = "Un autre téléchargement est déjà en cours."
            return
        }
        errorMessage = nil
        isDownloading = true
        defer { isDownloading = false }

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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Vérifie explicitement le statut HTTP. `URLSession.download` considère
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

        let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
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
