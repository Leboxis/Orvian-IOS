import SwiftUI

/// Sélecteur de dossier utilisé pour déplacer un ou plusieurs éléments.
/// Les dossiers eux-mêmes sélectionnés sont retirés de l'arborescence afin
/// d'empêcher de déplacer un dossier dans lui-même ou dans un descendant.
struct MoveDestinationPicker: View {
    let driveId: Int
    let itemCount: Int
    let excludedDirectoryIDs: Set<Int>
    let unavailableDestinationIDs: Set<Int>
    let onSelect: (DriveFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: MoveDestinationModel
    @State private var showCreateFolder = false
    @State private var folderName = ""
    @State private var operation: Task<Void, Never>?

    init(driveId: Int, itemCount: Int, excludedDirectoryIDs: Set<Int>,
         unavailableDestinationIDs: Set<Int>, files: [DriveFile], initialDirectory: DriveFile?,
         onSelect: @escaping (DriveFile) -> Void) {
        self.driveId = driveId
        self.itemCount = itemCount
        self.excludedDirectoryIDs = excludedDirectoryIDs
        self.unavailableDestinationIDs = unavailableDestinationIDs
        self.onSelect = onSelect
        _model = State(initialValue: MoveDestinationModel(driveId: driveId, files: files, initialDirectory: initialDirectory))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let directory = model.directory {
                    if excludedDirectoryIDs.contains(directory.id) {
                        ContentUnavailableView("Destination indisponible", systemImage: "folder.badge.questionmark",
                            description: Text("Remontez au dossier parent pour sortir des éléments à déplacer."))
                    } else {
                        DestinationFolderLevel(directory: directory, driveId: driveId,
                            excludedDirectoryIDs: excludedDirectoryIDs, reloadRevision: model.reloadRevision,
                            onOpen: model.open)
                            .id(directory.id)
                            .disabled(model.isBusy)
                    }
                } else if model.isBusy {
                    ProgressView("Chargement du dossier d’origine…")
                } else {
                    ContentUnavailableView {
                        Label("Dossier d’origine indisponible", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Réessayez de charger le dossier contenant les éléments.")
                    } actions: {
                        Button("Réessayer") { operation = Task { await model.loadStart() } }
                    }
                }
            }
            .navigationTitle(model.directory?.name ?? "Déplacer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    roundButton("Annuler", symbol: "xmark") { dismiss() }
                    roundButton("Dossier parent", symbol: "arrow.up") {
                        operation = Task { await model.goUp() }
                    }
                    .disabled(!model.canGoUp || model.isBusy)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    roundButton("Nouveau dossier", symbol: "folder.badge.plus") { showCreateFolder = true }
                        .disabled(model.directory == nil || model.isBusy || excludedDirectoryIDs.contains(model.directory?.id ?? -1))
                    roundButton("Déplacer \(itemCount) élément\(itemCount > 1 ? "s" : "") ici", symbol: "arrow.right") {
                        operation = Task {
                            if let destination = await model.confirmedDestination() { onSelect(destination) }
                        }
                    }
                    .disabled(model.isBusy || model.directory == nil
                        || unavailableDestinationIDs.contains(model.directory?.id ?? -1)
                        || excludedDirectoryIDs.contains(model.directory?.id ?? -1))
                }
            }
        }
        .task { await model.loadStart() }
        .onDisappear { operation?.cancel() }
        .alert("Nouveau dossier", isPresented: $showCreateFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let name = folderName
                operation = Task { if await model.createFolder(name: name) { folderName = "" } }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Annuler", role: .cancel) {}
        }
        .alert("Action impossible", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private func roundButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct DestinationFolderLevel: View {
    let directory: DriveFile
    let driveId: Int
    let excludedDirectoryIDs: Set<Int>
    let reloadRevision: Int
    let onOpen: (DriveFile) -> Void

    @State private var viewModel: FileGridViewModel
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"

    init(
        directory: DriveFile,
        driveId: Int,
        excludedDirectoryIDs: Set<Int>,
        reloadRevision: Int,
        onOpen: @escaping (DriveFile) -> Void
    ) {
        self.directory = directory
        self.driveId = driveId
        self.excludedDirectoryIDs = excludedDirectoryIDs
        self.reloadRevision = reloadRevision
        self.onOpen = onOpen
        _viewModel = State(initialValue: FileGridViewModel(source: .directory(directory.id), driveId: driveId))
    }

    private var folders: [DriveFile] {
        viewModel.items.filter {
            $0.isDirectory && !excludedDirectoryIDs.contains($0.id)
        }
    }

    var body: some View {
        List {
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
        .refreshable { await viewModel.reload(forceNetwork: true) }
        .task(id: reloadRevision) {
            if reloadRevision == 0 { await viewModel.loadIfNeeded() }
            else { await viewModel.reload(forceNetwork: true) }
        }
    }

}
