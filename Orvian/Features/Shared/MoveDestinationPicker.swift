import SwiftUI

/// Sélecteur de dossier utilisé pour déplacer un ou plusieurs éléments.
/// Les dossiers eux-mêmes sélectionnés sont retirés de l'arborescence afin
/// d'empêcher de déplacer un dossier dans lui-même ou dans un descendant.
struct MoveDestinationPicker: View {
    let driveId: Int
    let itemCount: Int
    let excludedDirectoryIDs: Set<Int>
    let unavailableDestinationIDs: Set<Int>
    let parentDirectory: DriveFile?
    let onSelect: (DriveFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [DriveFile] = []

    private let root = DriveFile.root(name: "Racine du drive")

    var body: some View {
        NavigationStack(path: $path) {
            destinationLevel(root)
                .navigationDestination(for: DriveFile.self) { folder in
                    destinationLevel(folder)
                }
        }
    }

    private func destinationLevel(_ directory: DriveFile) -> some View {
        DestinationFolderLevel(
            directory: directory,
            driveId: driveId,
            itemCount: itemCount,
            excludedDirectoryIDs: excludedDirectoryIDs,
            isCurrentDestinationUnavailable: unavailableDestinationIDs.contains(directory.id),
            parentDirectory: directory.id == root.id ? parentDirectory : nil,
            onOpen: { path.append($0) },
            onSelect: onSelect
        )
        .navigationTitle(directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Annuler") { dismiss() }
            }
        }
    }
}

private struct DestinationFolderLevel: View {
    let directory: DriveFile
    let driveId: Int
    let itemCount: Int
    let excludedDirectoryIDs: Set<Int>
    let isCurrentDestinationUnavailable: Bool
    let parentDirectory: DriveFile?
    let onOpen: (DriveFile) -> Void
    let onSelect: (DriveFile) -> Void

    @State private var viewModel: FileGridViewModel
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"

    init(
        directory: DriveFile,
        driveId: Int,
        itemCount: Int,
        excludedDirectoryIDs: Set<Int>,
        isCurrentDestinationUnavailable: Bool,
        parentDirectory: DriveFile?,
        onOpen: @escaping (DriveFile) -> Void,
        onSelect: @escaping (DriveFile) -> Void
    ) {
        self.directory = directory
        self.driveId = driveId
        self.itemCount = itemCount
        self.excludedDirectoryIDs = excludedDirectoryIDs
        self.isCurrentDestinationUnavailable = isCurrentDestinationUnavailable
        self.parentDirectory = parentDirectory
        self.onOpen = onOpen
        self.onSelect = onSelect
        _viewModel = State(initialValue: FileGridViewModel(source: .directory(directory.id), driveId: driveId))
    }

    private var folders: [DriveFile] {
        viewModel.items.filter {
            $0.isDirectory && !excludedDirectoryIDs.contains($0.id)
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    onSelect(directory)
                } label: {
                    Label(
                        isCurrentDestinationUnavailable ? "Déjà dans ce dossier" : selectTitle,
                        systemImage: isCurrentDestinationUnavailable ? "checkmark.circle" : "folder.badge.plus"
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .fontWeight(.semibold)
                }
                .disabled(isCurrentDestinationUnavailable)
            }

            if let parentDirectory {
                Section {
                    Button {
                        onOpen(parentDirectory)
                    } label: {
                        Label("Accéder au dossier parent", systemImage: "arrow.up.folder")
                    }
                }
            }

            Section("Sous-dossiers") {
                if viewModel.isInitialLoading {
                    HStack {
                        Spacer()
                        ProgressView("Chargement…")
                        Spacer()
                    }
                } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                    ContentUnavailableView {
                        Label("Impossible de charger", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Réessayer") { Task { await viewModel.reload() } }
                    }
                } else if folders.isEmpty {
                    Text("Aucun sous-dossier")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                        Button {
                            onOpen(folder)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(folder.color.flatMap { Color(hex: $0) } ?? Color(hex: defaultFolderColor) ?? .accentColor)
                                Text(folder.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if index >= folders.count - 3 {
                                Task { await viewModel.loadMoreIfNeeded() }
                            }
                        }
                    }

                    if viewModel.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
        }
        .refreshable { await viewModel.reload() }
        .task { await viewModel.loadIfNeeded() }
    }

    private var selectTitle: String {
        "Déplacer \(itemCount) élément\(itemCount > 1 ? "s" : "") ici"
    }
}
