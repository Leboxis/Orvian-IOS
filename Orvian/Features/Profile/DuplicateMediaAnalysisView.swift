import Observation
import SwiftUI

/// Écran interne d'analyse des doublons de médias d'un dossier kDrive.
/// L'analyse est volontairement non destructive : elle ne supprime rien et
/// présente des candidats ayant le même nom et la même taille.
struct DuplicateMediaAnalysisView: View {
    let driveId: Int
    let router: ViewerRouter

    @State private var analysis = DuplicateMediaAnalysisModel()
    @State private var showsFolderPicker = false

    var body: some View {
        List {
            Section {
                Button {
                    showsFolderPicker = true
                } label: {
                    Label(
                        analysis.selectedFolder?.name ?? "Choisir un dossier",
                        systemImage: "folder"
                    )
                }

                if let folder = analysis.selectedFolder {
                    Button {
                        Task { await analysis.analyze(folder: folder, driveId: driveId) }
                    } label: {
                        Label("Relancer l’analyse", systemImage: "arrow.clockwise")
                    }
                    .disabled(analysis.isAnalyzing)
                }
            } header: {
                Text("Dossier à analyser")
            } footer: {
                Text("L’analyse inclut les sous-dossiers et ne modifie aucun fichier.")
            }

            if analysis.isAnalyzing {
                Section("Analyse en cours") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("\(analysis.scannedMediaCount) média\(analysis.scannedMediaCount > 1 ? "s" : "") parcouru\(analysis.scannedMediaCount > 1 ? "s" : "")")
                    }
                }
            } else if let errorMessage = analysis.errorMessage {
                Section {
                    ContentUnavailableView {
                        Label("Analyse impossible", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        if let folder = analysis.selectedFolder {
                            Button("Réessayer") {
                                Task { await analysis.analyze(folder: folder, driveId: driveId) }
                            }
                        }
                    }
                }
            } else if analysis.hasFinished {
                resultsSection
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Choisissez un dossier", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Sélectionnez le dossier dont vous souhaitez vérifier les médias.")
                    }
                }
            }
        }
        .navigationTitle("Doublons de médias")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsFolderPicker) {
            DuplicateMediaFolderPicker(driveId: driveId) { folder in
                Task { await analysis.analyze(folder: folder, driveId: driveId) }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if analysis.duplicateGroups.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("Aucun doublon probable", systemImage: "checkmark.circle")
                } description: {
                    Text("Aucun média de même nom et de même taille n’a été trouvé dans ce dossier.")
                }
            }
        } else {
            Section {
                Label(
                    "\(analysis.duplicateGroups.count) groupe\(analysis.duplicateGroups.count > 1 ? "s" : "") trouvé\(analysis.duplicateGroups.count > 1 ? "s" : "")",
                    systemImage: "doc.on.doc"
                )
                Label(
                    "\(ByteFormatter.string(fromBytes: analysis.reclaimableBytes)) potentiellement libérables",
                    systemImage: "externaldrive"
                )
            } header: {
                Text("Doublons probables")
            } footer: {
                Text("Les candidats sont regroupés par nom et taille identiques. Vérifiez leur contenu avant toute suppression.")
            }

            ForEach(analysis.duplicateGroups) { group in
                Section {
                    ForEach(group.files) { file in
                        Button {
                            router.open(file, siblings: group.files)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name)
                                    .foregroundStyle(.primary)
                                Text(file.path ?? "Emplacement indisponible")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(group.displayName)
                        Spacer()
                        Text("\(group.files.count) médias · \(ByteFormatter.string(fromBytes: group.size))")
                    }
                    .font(.footnote)
                }
            }
        }
    }
}

@MainActor
@Observable
private final class DuplicateMediaAnalysisModel {
    private let service = KDriveService()

    var selectedFolder: DriveFile?
    var duplicateGroups: [DuplicateMediaGroup] = []
    var scannedMediaCount = 0
    var isAnalyzing = false
    var hasFinished = false
    var errorMessage: String?

    var reclaimableBytes: Int {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    func analyze(folder: DriveFile, driveId: Int) async {
        guard !isAnalyzing else { return }

        selectedFolder = folder
        duplicateGroups = []
        scannedMediaCount = 0
        errorMessage = nil
        hasFinished = false
        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            var cursor: String?
            var seenIDs: Set<Int> = []
            var media: [DriveFile] = []

            while true {
                let page = try await service.page(
                    .search(query: "", directoryId: folder.id),
                    driveId: driveId,
                    cursor: cursor
                )

                for file in page.data ?? [] where (file.isImage || file.isVideo) && seenIDs.insert(file.id).inserted {
                    media.append(file)
                }
                scannedMediaCount = media.count

                guard page.hasMore == true, let nextCursor = page.cursor else { break }
                cursor = nextCursor
            }

            let grouped = Dictionary(grouping: media.filter { $0.size != nil }) {
                DuplicateMediaKey(file: $0)
            }

            duplicateGroups = grouped
                .values
                .filter { $0.count > 1 }
                .map(DuplicateMediaGroup.init(files:))
                .sorted {
                    if $0.reclaimableBytes != $1.reclaimableBytes {
                        return $0.reclaimableBytes > $1.reclaimableBytes
                    }
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }

            hasFinished = true
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct DuplicateMediaKey: Hashable {
    let normalizedName: String
    let size: Int

    init(file: DriveFile) {
        normalizedName = file.name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        size = file.size ?? -1
    }
}

private struct DuplicateMediaGroup: Identifiable {
    let files: [DriveFile]

    init(files: [DriveFile]) {
        self.files = files.sorted {
            ($0.path ?? $0.name).localizedStandardCompare($1.path ?? $1.name) == .orderedAscending
        }
    }

    var id: String {
        "\(displayName)-\(size)"
    }

    var displayName: String {
        files.first?.name ?? "Média"
    }

    var size: Int? {
        files.first?.size
    }

    var reclaimableBytes: Int {
        max(0, files.count - 1) * (size ?? 0)
    }
}

/// Navigateur de dossiers utilisé uniquement avant le lancement de l'analyse.
private struct DuplicateMediaFolderPicker: View {
    let driveId: Int
    let onSelect: (DriveFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [DriveFile] = []

    private let root = DriveFile(
        id: 1,
        name: "Racine du drive",
        type: "dir",
        size: nil,
        mimeType: nil,
        extensionType: "dir",
        isFavorite: nil,
        parentId: nil,
        path: nil,
        color: nil,
        categories: nil,
        addedAt: nil,
        lastModifiedAt: nil
    )

    var body: some View {
        NavigationStack(path: $path) {
            folderLevel(root)
                .navigationDestination(for: DriveFile.self) { folder in
                    folderLevel(folder)
                }
        }
    }

    private func folderLevel(_ folder: DriveFile) -> some View {
        DuplicateMediaFolderLevel(
            folder: folder,
            driveId: driveId,
            onOpen: { path.append($0) },
            onSelect: {
                onSelect($0)
                dismiss()
            }
        )
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Annuler") { dismiss() }
            }
        }
    }
}

private struct DuplicateMediaFolderLevel: View {
    let folder: DriveFile
    let driveId: Int
    let onOpen: (DriveFile) -> Void
    let onSelect: (DriveFile) -> Void

    @State private var viewModel: FileGridViewModel

    init(
        folder: DriveFile,
        driveId: Int,
        onOpen: @escaping (DriveFile) -> Void,
        onSelect: @escaping (DriveFile) -> Void
    ) {
        self.folder = folder
        self.driveId = driveId
        self.onOpen = onOpen
        self.onSelect = onSelect
        _viewModel = State(initialValue: FileGridViewModel(source: .directory(folder.id), driveId: driveId))
    }

    private var folders: [DriveFile] {
        viewModel.items.filter(\.isDirectory)
    }

    var body: some View {
        List {
            Section {
                Button {
                    onSelect(folder)
                } label: {
                    Label("Analyser ce dossier", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .fontWeight(.semibold)
                }
            }

            Section("Sous-dossiers") {
                if viewModel.isInitialLoading {
                    HStack {
                        Spacer()
                        ProgressView("Chargement…")
                        Spacer()
                    }
                } else if let errorMessage = viewModel.errorMessage, folders.isEmpty {
                    ContentUnavailableView {
                        Label("Impossible de charger", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Réessayer") { Task { await viewModel.reload() } }
                    }
                } else if folders.isEmpty {
                    Text("Aucun sous-dossier")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { index, child in
                        Button {
                            onOpen(child)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(child.color.flatMap { Color(hex: $0) } ?? .accentColor)
                                Text(child.name)
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
        .refreshable { await viewModel.reload() }
        .task { await viewModel.loadIfNeeded() }
    }
}
