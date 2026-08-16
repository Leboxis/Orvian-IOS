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
        isDownloading = true
        defer { isDownloading = false }

        do {
            guard let remoteURL = await MediaURLCache.shared.url(driveId: driveId, fileId: file.id) else {
                throw NSError(
                    domain: "FileDownloadService",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Impossible d'obtenir le lien de téléchargement."]
                )
            }

            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
            let sanitizedName = file.name.replacingOccurrences(of: "/", with: "-")
            let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedName)

            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            presentShareSheet(for: destinationURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ouvre le menu de partage natif iOS (UIActivityViewController) : Enregistrer dans Fichiers, Enregistrer l'image/vidéo, AirDrop, etc.
    private func presentShareSheet(for fileURL: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
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
        topVC.present(activityVC, animated: true)
    }
}
