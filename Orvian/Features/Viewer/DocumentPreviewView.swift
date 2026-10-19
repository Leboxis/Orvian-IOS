import QuickLook
import SwiftUI

/// Aperçu natif (QuickLook) des documents qui ne sont ni une image, ni une
/// vidéo, ni un texte éditable : PDF, Word, Excel, archives, audio…
///
/// Avant, `ViewerRouter` envoyait ces fichiers vers `TextFileViewer`, qui les
/// refusait (« Ce fichier n'est pas un document texte ») : un PDF ou un MP3
/// était donc inaccessible depuis l'app.
struct DocumentPreviewScreen: View {
    let driveId: Int
    let file: DriveFile

    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let localURL {
                    DocumentPreviewController(url: localURL, title: file.name)
                        .ignoresSafeArea(edges: .bottom)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Aperçu impossible", systemImage: "doc.questionmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Réessayer") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Préparation de l’aperçu…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .task(id: file.id) { await load() }
    }

    private func load() async {
        errorMessage = nil
        do {
            localURL = try await DocumentPreviewLoader.localCopy(driveId: driveId, file: file)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Télécharge une copie locale : QuickLook n'ouvre que des fichiers présents
/// sur le disque, jamais une URL distante.
enum DocumentPreviewLoader {
    static func localCopy(driveId: Int, file: DriveFile) async throws -> URL {
        guard let remoteURL = await MediaURLCache.shared.url(driveId: driveId, fileId: file.id) else {
            throw PreviewError.missingTemporaryURL
        }
        let (firstURL, response) = try await download(remoteURL, named: file)
        guard let http = response as? HTTPURLResponse else {
            removeCopy(firstURL)
            throw PreviewError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) {
            return firstURL
        }
        removeCopy(firstURL)
        // Le lien signé expire au bout de 55 minutes : une seule nouvelle
        // demande, comme pour l'éditeur de texte.
        guard [401, 403, 404, 410].contains(http.statusCode),
              let freshURL = await MediaURLCache.shared.freshURL(driveId: driveId, fileId: file.id)
        else { throw PreviewError.http(status: http.statusCode) }
        let (secondURL, secondResponse) = try await download(freshURL, named: file)
        guard let secondHTTP = secondResponse as? HTTPURLResponse,
              (200..<300).contains(secondHTTP.statusCode) else {
            removeCopy(secondURL)
            throw PreviewError.http(status: (secondResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return secondURL
    }

    /// `URLSession` rend un fichier temporaire qui peut disparaître dès que la
    /// session est invalidée : on le déplace tout de suite dans notre propre
    /// dossier, sous un nom sûr.
    private static func download(_ url: URL, named file: DriveFile) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 5 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporaryURL, response) = try await session.download(from: url)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrvianPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(safeName(for: file), isDirectory: false)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return (destination, response)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Supprime la copie refusée et son dossier (vide après le retrait).
    private static func removeCopy(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Le nom vient du serveur : il ne doit jamais créer de sous-dossier.
    private static func safeName(for file: DriveFile) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        let sanitized = file.name
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            return "Document-\(file.id)"
        }
        return sanitized
    }

    enum PreviewError: LocalizedError {
        case missingTemporaryURL
        case invalidResponse
        case http(status: Int)

        var errorDescription: String? {
            switch self {
            case .missingTemporaryURL:
                return "Impossible d’obtenir le lien du fichier."
            case .invalidResponse:
                return "Le serveur a renvoyé une réponse invalide."
            case let .http(status):
                return "Le fichier n’a pas pu être téléchargé (HTTP \(status))."
            }
        }
    }
}

/// Enveloppe `QLPreviewController`, qui gère seul le rendu des PDF, des
/// documents Office, de l’audio et des archives.
private struct DocumentPreviewController: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.item = PreviewItem(url: url, title: title)
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(item: PreviewItem(url: url, title: title))
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var item: PreviewItem
        init(item: PreviewItem) { self.item = item }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem {
            item
        }
    }

    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL, title: String) {
            previewItemURL = url
            previewItemTitle = title
        }
    }
}
