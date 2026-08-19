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
    let onDone: ([DriveFile]) -> Void

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
            DocumentPicker { urls in
                guard !urls.isEmpty else { return }
                UploadManager.shared.enqueueDocuments(driveId: driveId, directoryId: directoryId, urls: urls) { uploadedFiles in
                    onDone(uploadedFiles)
                }
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
            let picked = items
            photoItems = []
            UploadManager.shared.enqueuePhotos(driveId: driveId, directoryId: directoryId, items: picked) { uploadedFiles in
                onDone(uploadedFiles)
            }
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
        onDone([])
    }

    // MARK: - Helpers

    private func message(for error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}
