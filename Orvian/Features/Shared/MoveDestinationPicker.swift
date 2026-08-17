import SwiftUI

/// Sélecteur de dossier de destination utilisé depuis le menu contextuel
/// d'une carte. Il n'affiche que des dossiers afin qu'un déplacement ne puisse
/// jamais cibler un fichier.
struct MoveDestinationPicker: View {
    let file: DriveFile
    let driveId: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [DriveFile] = []

    var body: some View {
        NavigationStack(path: $path) {
            MoveDestinationDirectory(
                directory: .root(name: "Racine du drive"),
                movingFile: file,
                driveId: driveId,
                onSelect: select
            )
            .navigationDestination(for: DriveFile.self) { directory in
                MoveDestinationDirectory(
                    directory: directory,
                    movingFile: file,
                    driveId: driveId,
                    onSelect: select
                )
            }
        }
    }

    private func select(_ directoryId: Int) {
        onSelect(directoryId)
        dismiss()
    }
}

private struct MoveDestinationDirectory: View {
    let directory: DriveFile
    let movingFile: DriveFile
    let driveId: Int
    let onSelect: (Int) -> Void

    @State private var folders: [DriveFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let service = KDriveService()

    private var isCurrentParent: Bool {
        movingFile.parentId == directory.id
    }

    var body: some View {
        List {
            Section {
                Button {
                    onSelect(directory.id)
                } label: {
                    Label(
                        isCurrentParent ? "Le fichier est déjà dans ce dossier" : "Déplacer ici",
                        systemImage: "folder.badge.plus"
                    )
                }
                .disabled(isCurrentParent)
            } footer: {
                Text("En cas de doublon, le fichier déplacé sera renommé automatiquement.")
            }

            Section("Sous-dossiers") {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Chargement…")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Impossible de charger", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Réessayer") { Task { await loadFolders() } }
                    }
                } else if folders.isEmpty {
                    Text("Aucun sous-dossier")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        NavigationLink(value: folder) {
                            Label(folder.name, systemImage: "folder.fill")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Déplacer vers")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: directory.id) {
            await loadFolders()
        }
    }

    private func loadFolders() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await service.page(.directory(directory.id), driveId: driveId, cursor: nil)
            guard !Task.isCancelled else { return }
            // On interdit au minimum de choisir le dossier déplacé lui-même.
            // L'API protège également contre un cycle vers l'un de ses enfants.
            folders = (page.data ?? []).filter { $0.isDirectory && $0.id != movingFile.id }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
