import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
                showFolderAlert = true
            } label: {
                Label("Créer un dossier", systemImage: "folder.badge.plus")
            }
            Button {
                showDocumentPicker = true
            } label: {
                Label("Importer des fichiers", systemImage: "doc.badge.plus")
            }
            Button {
                showPhotosPicker = true
            } label: {
                Label("Photos et vidéos", systemImage: "photo.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(isBusy)
        .accessibilityLabel("Ajouter")
        .alert("Créer un dossier", isPresented: $showFolderAlert) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") { Task { await createFolder() } }
            Button("Annuler", role: .cancel) {}
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { urls in
                Task { await importFiles(urls) }
            }
            .ignoresSafeArea()
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

    private func createFolder() async {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        folderName = ""
        guard !name.isEmpty else { return }
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
    /// (gestion des URLs security-scoped pour iCloud Drive, clés USB et partages SMB).
    private func importFiles(_ urls: [URL]) async {
        isBusy = true
        busyMessage = "Lecture des fichiers…"
        var filesToUpload: [(data: Data, name: String)] = []

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if let data = try? await Task.detached(operation: { try Data(contentsOf: url) }).value {
                filesToUpload.append((data: data, name: url.lastPathComponent))
            }
        }

        isBusy = false
        guard !filesToUpload.isEmpty else { return }
        UploadManager.shared.enqueue(driveId: driveId, directoryId: directoryId, files: filesToUpload) {
            onDone()
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        photoItems = []
        isBusy = true
        busyMessage = "Préparation des photos…"
        var filesToUpload: [(data: Data, name: String)] = []

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                filesToUpload.append((data: data, name: fileName(for: item)))
            }
        }

        isBusy = false
        guard !filesToUpload.isEmpty else { return }
        UploadManager.shared.enqueue(driveId: driveId, directoryId: directoryId, files: filesToUpload) {
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