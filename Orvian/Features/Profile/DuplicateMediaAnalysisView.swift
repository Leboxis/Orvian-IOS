import Observation
import SwiftUI
import UIKit

/// Écran interne d'analyse des doublons de médias d'un dossier kDrive.
/// L'analyse est volontairement non destructive : elle ne supprime rien et
/// présente des candidats ayant le même nom et la même taille.
struct DuplicateMediaAnalysisView: View {
    let driveId: Int
    let router: ViewerRouter

    @State private var analysis = DuplicateMediaAnalysisModel()
    @State private var analysisTask: Task<Void, Never>?
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
                        startAnalysis(in: folder)
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
                        Text(analysis.wasStopped
                             ? "Arrêt de l’analyse…"
                             : analysis.isAnalyzingThumbnails
                                ? "\(analysis.analyzedThumbnailCount)/\(analysis.scannedMediaCount) miniature\(analysis.analyzedThumbnailCount > 1 ? "s" : "") analysée\(analysis.analyzedThumbnailCount > 1 ? "s" : "")"
                                : "\(analysis.scannedMediaCount) média\(analysis.scannedMediaCount > 1 ? "s" : "") parcouru\(analysis.scannedMediaCount > 1 ? "s" : "")")
                    }

                    Button(role: .destructive) {
                        stopAnalysis()
                    } label: {
                        Label("Arrêter et afficher les résultats", systemImage: "stop.circle")
                    }
                    .disabled(analysis.wasStopped)
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
                                startAnalysis(in: folder)
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
                startAnalysis(in: folder)
            }
        }
        .onDisappear {
            stopAnalysis()
        }
    }

    private func startAnalysis(in folder: DriveFile) {
        analysisTask?.cancel()
        analysisTask = Task {
            await analysis.analyze(folder: folder, driveId: driveId)
        }
    }

    private func stopAnalysis() {
        guard analysis.isAnalyzing else { return }
        analysis.stop()
        analysisTask?.cancel()
    }

    @ViewBuilder
    private var resultsSection: some View {
        if analysis.duplicateGroups.isEmpty && analysis.similarityGroups.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("Aucun doublon probable", systemImage: "checkmark.circle")
                } description: {
                    Text("Aucun média identique ou visuellement similaire n’a été trouvé dans ce dossier.")
                }
            }
        } else {
            if !analysis.duplicateGroups.isEmpty {
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
                    Text(analysis.wasStopped ? "Doublons exacts — résultats partiels" : "Doublons exacts")
                } footer: {
                    Text("Les candidats sont regroupés par nom et taille identiques. Vérifiez leur contenu avant toute suppression.")
                }

                ForEach(analysis.duplicateGroups) { group in
                    mediaGroupSection(group.files, title: "\(group.displayName) · \(ByteFormatter.string(fromBytes: group.size))")
                }
            }

            if !analysis.similarityGroups.isEmpty {
                Section {
                    Label(
                        "\(analysis.similarityGroups.count) groupe\(analysis.similarityGroups.count > 1 ? "s" : "") trouvé\(analysis.similarityGroups.count > 1 ? "s" : "")",
                        systemImage: "photo.on.rectangle.angled"
                    )
                } header: {
                    Text(analysis.wasStopped ? "Miniatures similaires — résultats partiels" : "Miniatures similaires (≥ 70 %)")
                } footer: {
                    Text("La similarité est calculée à partir de l’empreinte visuelle des miniatures ; elle n’atteste pas que les fichiers sont identiques.")
                }

                ForEach(analysis.similarityGroups) { group in
                    Section {
                        ForEach(group.matches) { match in
                            Button {
                                router.open(match.file, siblings: group.files)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(match.file.name)
                                        .foregroundStyle(.primary)
                                    Text("\(Int((match.similarity * 100).rounded())) % similaire · \(match.file.path ?? "Emplacement indisponible")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Référence : \(group.reference.name)")
                            .font(.footnote)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mediaGroupSection(_ files: [DriveFile], title: String) -> some View {
        Section {
            ForEach(files) { file in
                Button {
                    router.open(file, siblings: files)
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
            Text(title)
                .font(.footnote)
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
    var wasStopped = false
    var isAnalyzingThumbnails = false
    var analyzedThumbnailCount = 0
    var errorMessage: String?
    var similarityGroups: [SimilarMediaGroup] = []

    private var seenIDs: Set<Int> = []
    private var media: [DriveFile] = []
    private var thumbnailFingerprints: [Int: UInt64] = [:]

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
        wasStopped = false
        isAnalyzingThumbnails = false
        analyzedThumbnailCount = 0
        similarityGroups = []
        seenIDs = []
        media = []
        thumbnailFingerprints = [:]
        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            var cursor: String?

            while !Task.isCancelled && !wasStopped {
                let page = try await service.page(
                    .search(query: "", directoryId: folder.id),
                    driveId: driveId,
                    cursor: cursor
                )

                guard !Task.isCancelled, !wasStopped else { break }

                for file in page.data ?? [] where (file.isImage || file.isVideo) && seenIDs.insert(file.id).inserted {
                    media.append(file)
                }
                scannedMediaCount = media.count
                rebuildDuplicateGroups()

                guard page.hasMore == true, let nextCursor = page.cursor else { break }
                cursor = nextCursor
            }

            if !Task.isCancelled && !wasStopped {
                isAnalyzingThumbnails = true
                for file in media {
                    guard !Task.isCancelled, !wasStopped else { break }

                    if let image = await ThumbnailProvider.shared.thumbnail(
                        driveId: driveId,
                        fileId: file.id,
                        pixels: 64
                    ), let fingerprint = perceptualHash(for: image) {
                        thumbnailFingerprints[file.id] = fingerprint
                        rebuildSimilarityGroups()
                    }
                    analyzedThumbnailCount += 1
                }
                isAnalyzingThumbnails = false
            }

            hasFinished = true
        } catch {
            if Task.isCancelled || wasStopped {
                hasFinished = true
            } else {
                errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func stop() {
        wasStopped = true
    }

    private func rebuildDuplicateGroups() {
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
    }

    private func rebuildSimilarityGroups() {
        let files = media.filter { thumbnailFingerprints[$0.id] != nil }
        var assignedIDs: Set<Int> = []
        var groups: [SimilarMediaGroup] = []

        for reference in files where !assignedIDs.contains(reference.id) {
            guard let referenceHash = thumbnailFingerprints[reference.id] else { continue }
            let matches = files.compactMap { candidate -> SimilarMediaMatch? in
                guard candidate.id != reference.id,
                      !assignedIDs.contains(candidate.id),
                      DuplicateMediaKey(file: candidate) != DuplicateMediaKey(file: reference),
                      let candidateHash = thumbnailFingerprints[candidate.id] else {
                    return nil
                }

                let similarity = thumbnailSimilarity(referenceHash, candidateHash)
                return similarity >= 0.7
                    ? SimilarMediaMatch(file: candidate, similarity: similarity)
                    : nil
            }

            guard !matches.isEmpty else { continue }
            assignedIDs.insert(reference.id)
            assignedIDs.formUnion(matches.map(\.file.id))
            groups.append(SimilarMediaGroup(reference: reference, matches: matches))
        }

        similarityGroups = groups.sorted {
            $0.reference.name.localizedStandardCompare($1.reference.name) == .orderedAscending
        }
    }
}


/// Empreinte de 64 bits d’une miniature ramenée à 8 × 8 pixels en niveaux de gris.
/// Elle permet une comparaison légère sans télécharger le média original.
private func perceptualHash(for image: UIImage) -> UInt64? {
    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let cgImage = image.cgImage,
          let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return nil
    }

    context.interpolationQuality = .medium
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

    var luminances: [Int] = []
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        luminances.append(red * 299 + green * 587 + blue * 114)
    }
    let average = luminances.reduce(0, +) / luminances.count

    return luminances.enumerated().reduce(UInt64(0)) { hash, item in
        item.element >= average ? hash | (UInt64(1) << UInt64(item.offset)) : hash
    }
}

private func thumbnailSimilarity(_ lhs: UInt64, _ rhs: UInt64) -> Double {
    1 - Double((lhs ^ rhs).nonzeroBitCount) / 64
}

private struct SimilarMediaMatch: Identifiable {
    let file: DriveFile
    let similarity: Double

    var id: Int { file.id }
}

private struct SimilarMediaGroup: Identifiable {
    let reference: DriveFile
    let matches: [SimilarMediaMatch]

    var id: Int { reference.id }
    var files: [DriveFile] { [reference] + matches.map(\.file) }
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
        "\(displayName)-\(size ?? -1)"
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
