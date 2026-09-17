import SwiftUI

// MARK: - Fiche détails

/// Fiche affichée au tap sur un élément du drive : infos, tags, favori,
/// et bouton Ouvrir.
struct FileDetailSheet: View {
    let file: DriveFile
    let driveId: Int
    /// Fichier corbeillé : la fiche reste consultable mais sans les actions
    /// favori/tags et la miniature passe par l'endpoint trash.
    var isTrashed = false
    let onOpen: () -> Void
    let onToggleFavorite: (() async -> Bool)?
    let onDelete: (() -> Void)?
    let onRename: ((String) -> Void)?
    let onMove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"
    /// Tags réellement appliqués au fichier (source : fiche individuelle).
    @State private var appliedCategories: [Category] = []
    @State private var isLoadingTags = true
    @State private var tagsError: String?
    @State private var isFavoriteMutationInProgress = false
    /// Chemin complet depuis la racine du drive, tel que renvoyé par l'API.
    @State private var filePath: String?
    @State private var showDeleteConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private let service = KDriveService()

    init(
        file: DriveFile,
        driveId: Int,
        isTrashed: Bool = false,
        onOpen: @escaping () -> Void,
        onToggleFavorite: (() async -> Bool)?,
        onDelete: (() -> Void)?,
        onRename: ((String) -> Void)?,
        onMove: (() -> Void)?
    ) {
        self.file = file
        self.driveId = driveId
        self.isTrashed = isTrashed
        self.onOpen = onOpen
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.onRename = onRename
        self.onMove = onMove
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    previewSection
                    openSection
                    infoSection
                    tagsSection
                    actionsSection
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Détails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .accessibilityLabel("Fermer")
                }

            }
            .alert("Supprimer", isPresented: $showDeleteConfirm) {
                Button("Supprimer", role: .destructive) { onDelete?() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("« \(file.name) » sera déplacé dans la corbeille.")
            }
            .alert("Renommer", isPresented: $showRenameAlert) {
                TextField("Nouveau nom", text: $renameText)
                Button("Renommer") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onRename?(trimmed) }
                    renameText = ""
                }
                Button("Annuler", role: .cancel) { renameText = "" }
            } message: {
                Text("Ancien nom : \(file.name)")
            }
            .task { await loadFileInfo() }
        }
    }

    private var previewSection: some View {
        VStack(spacing: 16) {
            thumbnailPreview
                .frame(width: 120, height: 120)
                .shadow(color: previewTint.opacity(0.16), radius: 16, y: 8)
                .accessibilityHidden(true)

            Text(file.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            Text(file.fileKind.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(previewTint)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(previewTint.opacity(0.10), in: Capsule())

            if isTrashed {
                Label("Dans la corbeille", systemImage: "trash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [previewTint.opacity(0.10), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
        }
    }

    private var infoSection: some View {
        detailSection("Informations", symbol: "info.circle") {
            labeledRow("Type", file.fileKind.label, symbol: file.fileKind.symbolName)
            if let size = file.size, !file.isDirectory {
                Divider()
                labeledRow("Taille", ByteFormatter.string(fromBytes: size), symbol: "internaldrive")
            }
            if let path = filePath ?? file.path, !path.isEmpty {
                Divider()
                labeledRow("Emplacement", path, symbol: "folder")
            }
            Divider()
            labeledRow("Ajouté le", dateText(file.addedAt), symbol: "calendar.badge.plus")
            Divider()
            labeledRow("Modifié le", dateText(file.lastModifiedAt), symbol: "clock")
        }
    }

    private var favoriteRow: some View {
        Button {
            toggleFavorite()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.isFavorite == true ? "star.fill" : "star")
                    .foregroundStyle(file.isFavorite == true ? Color.yellow : Color.accentColor)
                    .frame(width: 24)
                Text(file.isFavorite == true ? "Retirer des favoris" : "Ajouter aux favoris")
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isFavoriteMutationInProgress {
                    ProgressView()
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFavoriteMutationInProgress || onToggleFavorite == nil)
    }

    private func toggleFavorite() {
        guard !isFavoriteMutationInProgress, let onToggleFavorite else { return }
        isFavoriteMutationInProgress = true
        Task {
            _ = await onToggleFavorite()
            isFavoriteMutationInProgress = false
        }
    }

    private var tagsSection: some View {
        detailSection("Tags", symbol: "tag") {
            if isTrashed {
                Text("Restaurer le fichier pour modifier ses tags.")
                    .foregroundStyle(.secondary)
            } else if isLoadingTags {
                ProgressView("Chargement des tags…")
            } else if let tagsError {
                Text(tagsError).font(.footnote).foregroundStyle(.secondary)
                Button("Réessayer") { Task { await loadFileInfo() } }
            } else if appliedCategories.isEmpty {
                Text("Aucun tag")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(appliedCategories) { category in
                        tagChip(category)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Pastille de tag (rond de couleur + nom) pour la grille de la fiche.
    private func tagChip(_ category: Category) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: category.color) ?? .gray)
                .frame(width: 10, height: 10)
            Text(category.name)
                .font(.footnote)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
    }

    private var openSection: some View {
        VStack(spacing: 12) {
            Button {
                dismiss()
                onOpen()
            } label: {
                Label(
                    file.isDirectory ? "Ouvrir le dossier" : "Ouvrir le fichier",
                    systemImage: file.isDirectory ? "folder" : "arrow.up.forward.square"
                )
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 16))

            if !file.isDirectory, !isTrashed {
                Button {
                    Task {
                        await FileDownloadService.shared.downloadAndShare(driveId: driveId, file: file)
                    }
                } label: {
                    Label("Télécharger", systemImage: "arrow.down.circle")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 16))
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if !isTrashed, onToggleFavorite != nil || onRename != nil || onDelete != nil {
            detailSection("Actions", symbol: "slider.horizontal.3") {
                if onToggleFavorite != nil {
                    favoriteRow
                }
                if onRename != nil {
                    if onToggleFavorite != nil { Divider() }
                    Button {
                        renameText = file.name
                        showRenameAlert = true
                    } label: {
                        actionLabel("Renommer", symbol: "pencil")
                    }
                    .buttonStyle(.plain)
                }
                if onDelete != nil {
                    if onToggleFavorite != nil || onRename != nil { Divider() }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        actionLabel("Déplacer dans la corbeille", symbol: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func detailSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var thumbnailPreview: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if file.isDirectory {
            ZStack {
                Rectangle().fill(folderTint.opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(folderTint)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
        } else {
            AsyncThumbnail(
                driveId: driveId,
                fileId: file.id,
                kind: file.fileKind,
                isTrashed: isTrashed,
                shape: shape
            )
        }
    }

    private var folderTint: Color {
        file.color.flatMap { Color(hex: $0) }
            ?? Color(hex: defaultFolderColor)
            ?? file.fileKind.tint
    }

    private var previewTint: Color {
        file.isDirectory ? folderTint : file.fileKind.tint
    }

    private func labeledRow(_ label: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(previewTint)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dateText(_ timestamp: Double?) -> String {
        guard let ts = timestamp else { return "—" }
        let date = Date(timeIntervalSince1970: ts)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadFileInfo() async {
        isLoadingTags = true
        tagsError = nil
        defer { isLoadingTags = false }
        guard !isTrashed else {
            // Sans réseau inutile : la liste fournit déjà le chemin quand l'API le renvoie.
            filePath = file.path
            return
        }
        filePath = file.path
        do {
            try await CategoryLibrary.shared.requireLoaded(for: driveId)
            let byId = CategoryLibrary.shared.categories(for: driveId)
            // Les listes (`with=is_favorite,categories,path`) fournissent déjà les
            // catégories, le favori et le chemin : la fiche s'affiche sans appel
            // réseau. Seule la recherche par tag (qui ne renvoie pas les
            // catégories) déclenche la fiche individuelle.
            if let categories = file.categories {
                appliedCategories = categories.compactMap { byId[$0.categoryId] }
                return
            }
            let info = try await service.fileInfo(driveId: driveId, fileId: file.id)
            appliedCategories = (info.categories ?? []).compactMap { byId[$0.categoryId] }
            if let infoPath = info.path, !infoPath.isEmpty {
                filePath = infoPath
            }
        } catch {
            tagsError = "Impossible de charger les tags : \(error.localizedDescription)"
        }
    }
}

/// Charge une miniature de manière asynchrone pour un affichage ponctuel.
private struct AsyncThumbnail<S: InsettableShape>: View {
    let driveId: Int
    let fileId: Int
    let kind: FileKind
    var isTrashed = false
    let shape: S

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Rectangle()
            .fill(kind.tint.opacity(0.10))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isLoading && kind.supportsThumbnail {
                    ProgressView()
                } else {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(kind.tint)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
            .task {
                defer { isLoading = false }
                guard kind.supportsThumbnail else { return }
                image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: fileId, isTrashed: isTrashed)
            }
    }
}
