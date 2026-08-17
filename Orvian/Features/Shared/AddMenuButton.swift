import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

/// Représentation fichier sur disque pour l'import Transferable PhotosUI
private struct PickedPhotoFile: Transferable {
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
            return PickedPhotoFile(url: tempURL)
        }
    }
}

/// Bouton « + » d'un dossier : créer un dossier, importer des fichiers
/// ou importer des photos/vidéos (upload kDrive).
struct AddMenuButton: View {
    let directoryId: Int
    let driveId: Int
    @Binding var isBusy: Bool
    @Binding var busyMessage: String
    @Binding var errorMessage: String?
    let onDone: () -> Void

    @State private var showFolderAlert = false
    @State private var folderName = ""
    @State private var showDocumentPicker = false
    @State private var showPhotosPicker = false
    @State private var photoItems: [PhotosPickerItem] = []

    private let service = KDriveService()

    var body: some View {
        Menu {
            Button {
                folderName = ""
                showFolderAlert = true
            } label: {
                Label("Nouveau dossier", systemImage: "folder.badge.plus")
            }
            Button {
                showPhotosPicker = true
            } label: {
                Label("Importer photos / vidéos", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                showDocumentPicker = true
            } label: {
                Label("Importer des fichiers", systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .disabled(isBusy)
        .alert("Nouveau dossier", isPresented: $showFolderAlert) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await createFolder(named: name) }
            }
            Button("Annuler", role: .cancel) {}
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(types: [.item], allowsMultiple: true) { urls in
                Task { await importFiles(urls) }
            }
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoItems,
            maxSelectionCount: 20,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
    }

    // MARK: - Actions

    private func createFolder(named name: String) async {
        isBusy = true
        busyMessage = "Création du dossier…"
        do {
            try await service.createFolder(driveId: driveId, directoryId: directoryId, name: name)
        } catch {
            errorMessage = "Dossier non créé : \(message(for: error))"
        }
        isBusy = false
        onDone()
    }

    /// Import d'un ou plusieurs fichiers choisis dans le document picker
    /// (gestion des URLs security-scoped avec copie locale vers dossier temporaire sans chargement RAM).
    private func importFiles(_ urls: [URL]) async {
        isBusy = true
        busyMessage = "Préparation des fichiers…"
        var payloads: [UploadPayload] = []

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
                let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                payloads.append(UploadPayload(fileURL: tempURL, fileName: url.lastPathComponent, totalBytes: size, isTemporary: true))
            } catch {
                // Erreur de copie ignorée pour ce fichier individuel
            }
        }

        isBusy = false
        guard !payloads.isEmpty else { return }
        UploadManager.shared.enqueue(driveId: driveId, directoryId: directoryId, files: payloads) {
            onDone()
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        photoItems = []
        isBusy = true
        busyMessage = "Préparation des médias…"
        var payloads: [UploadPayload] = []

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for (index, item) in items.enumerated() {
            let contentType = item.supportedContentTypes.first ?? .data
            let ext = contentType.preferredFilenameExtension ?? "jpg"
            let name = "Import-\(Int(Date().timeIntervalSince1970))-\(index + 1).\(ext)"

            if let picked = try? await item.loadTransferable(type: PickedPhotoFile.self) {
                let size = (try? picked.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                payloads.append(UploadPayload(fileURL: picked.url, fileName: name, totalBytes: size, isTemporary: true))
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let tempURL = tempDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: tempURL)
                do {
                    try data.write(to: tempURL, options: .atomic)
                    payloads.append(UploadPayload(fileURL: tempURL, fileName: name, totalBytes: data.count, isTemporary: true))
                } catch {}
            }
        }

        isBusy = false
        guard !payloads.isEmpty else { return }
        UploadManager.shared.enqueue(driveId: driveId, directoryId: directoryId, files: payloads) {
            onDone()
        }
    }

    // MARK: - Helpers

    private func upload(data: Data, fileName: String) async throws {
        let mimeType = UTType(filenameExtension: (fileName as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        try await service.upload(driveId: driveId, directoryId: directoryId, data: data, fileName: fileName, mimeType: mimeType)
    }

    private func fileName(for item: PhotosPickerItem) -> String {
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        return "Import-\(Int(Date().timeIntervalSince1970)).\(ext)"
    }

    private func message(for error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}