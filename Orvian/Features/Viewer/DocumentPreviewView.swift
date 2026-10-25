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
    @State private var lifetime = DocumentPreviewLifetime()
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            Group {
                if let copy = lifetime.copy {
                    DocumentPreviewController(copy: copy, title: file.name)
                        .ignoresSafeArea(edges: .bottom)
                } else if let errorMessage = lifetime.errorMessage {
                    ContentUnavailableView {
                        Label("Aperçu impossible", systemImage: "doc.questionmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Réessayer") { retry &+= 1 }
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
        .task(id: "\(file.id)-\(retry)") {
            await lifetime.load {
                try await DocumentPreviewLoader.localCopy(driveId: driveId, file: file)
            }
        }
        .onDisappear { lifetime.cancelLoading() }
    }
}

/// Télécharge une copie locale : QuickLook n'ouvre que des fichiers présents
/// sur le disque, jamais une URL distante.
enum DocumentPreviewLoader {
    static func localCopy(driveId: Int, file: DriveFile) async throws -> DocumentPreviewCopy {
        guard let remoteURL = await MediaURLCache.shared.url(driveId: driveId, fileId: file.id) else {
            throw PreviewError.missingTemporaryURL
        }
        let (firstCopy, response) = try await download(remoteURL, named: file)
        guard let http = response as? HTTPURLResponse else {
            throw PreviewError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) {
            return firstCopy
        }
        // Le lien signé expire au bout de 55 minutes : une seule nouvelle
        // demande, comme pour l'éditeur de texte.
        guard [401, 403, 404, 410].contains(http.statusCode),
              let freshURL = await MediaURLCache.shared.freshURL(driveId: driveId, fileId: file.id)
        else { throw PreviewError.http(status: http.statusCode) }
        let (secondCopy, secondResponse) = try await download(freshURL, named: file)
        guard let secondHTTP = secondResponse as? HTTPURLResponse,
              (200..<300).contains(secondHTTP.statusCode) else {
            throw PreviewError.http(status: (secondResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return secondCopy
    }

    /// `URLSession` rend un fichier temporaire qui peut disparaître dès que la
    /// session est invalidée : on le déplace tout de suite dans notre propre
    /// dossier, sous un nom sûr.
    private static func download(_ url: URL, named file: DriveFile) async throws -> (DocumentPreviewCopy, URLResponse) {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 5 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporaryURL, response) = try await session.download(from: url)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrvianPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(safeName(for: file), isDirectory: false)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try Task.checkCancellation()
            return (DocumentPreviewCopy(url: destination), response)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
    let copy: DocumentPreviewCopy
    let title: String

    func makeUIViewController(context: Context) -> RetainingPreviewController {
        let controller = RetainingPreviewController()
        controller.retainedItem = context.coordinator.item
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: RetainingPreviewController, context: Context) {
        guard context.coordinator.item.copy !== copy else { return }
        context.coordinator.item = PreviewItem(copy: copy, title: title)
        controller.retainedItem = context.coordinator.item
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(item: PreviewItem(copy: copy, title: title))
    }

    final class RetainingPreviewController: QLPreviewController {
        var retainedItem: PreviewItem?
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
        let copy: DocumentPreviewCopy
        var previewItemURL: URL? { copy.url }
        let previewItemTitle: String?

        init(copy: DocumentPreviewCopy, title: String) {
            self.copy = copy
            previewItemTitle = title
        }
    }
}
