import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Bouton « + » d'un dossier : créer un dossier, importer un fichier
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
    @State private var showFileImporter = false
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
                showFileImporter = true
            } label: {
                Label("Importer un fichier", systemImage: "doc.badge.plus")
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
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                Task { await importFile(url: url) }
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

    private func importFile(url: URL) async {
        isBusy = true
        busyMessage = "Import en cours…"
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            // Lecture hors du MainActor : un gros fichier ne fige pas l'UI.
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            try await upload(data: data, fileName: url.lastPathComponent)
        } catch {
            errorMessage = "Import impossible : \(message(for: error))"
        }
        isBusy = false
        onDone()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        photoItems = []
        isBusy = true
        var failures = 0
        for (index, item) in items.enumerated() {
            busyMessage = "Import \(index + 1)/\(items.count)…"
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    failures += 1
                    continue
                }
                try await upload(data: data, fileName: fileName(for: item))
            } catch {
                failures += 1
            }
        }
        isBusy = false
        if failures > 0 {
            errorMessage = "\(failures) élément(s) n'ont pas pu être importés."
        }
        onDone()
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