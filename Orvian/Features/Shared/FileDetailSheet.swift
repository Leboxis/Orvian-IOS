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
    let onToggleFavorite: (() -> Void)?
    let onDelete: (() -> Void)?
    let onRename: ((String) -> Void)?
    let onMove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"
    /// Tags réellement appliqués au fichier (source : fiche individuelle).
    @State private var appliedCategories: [Category] = []
    @State private var isFavorite: Bool
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
        onToggleFavorite: (() -> Void)?,
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
        _isFavorite = State(initialValue: file.isFavorite == true)
    }

    var body: some View {
        NavigationStack {
            List {
                previewSection
                infoSection
                tagsSection
                openSection
            }
            .navigationTitle(file.name)
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
                if !isTrashed {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if onToggleFavorite != nil {
                            Button {
                                isFavorite.toggle()
                                onToggleFavorite?()
                            } label: {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .foregroundStyle(isFavorite ? .yellow : Color.accentColor)
                            }
                            .accessibilityLabel(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
                        }

                        if onDelete != nil {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Supprimer")
                        }
                    }
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
        Section {
            HStack {
                Spacer()
                thumbnailPreview
                    .frame(width: 80, height: 80)
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    private var infoSection: some View {
        Section("Informations") {
            labeledRow("Type", file.isDirectory ? "Dossier" : file.fileKind.label)
            if let size = file.size, !file.isDirectory {
                labeledRow("Taille", ByteFormatter.string(fromBytes: size))
            }
            if let filePath, !filePath.isEmpty {
                locationRow(filePath)
            }
            labeledRow("Ajouté", dateText(file.addedAt))
            labeledRow("Modifié", dateText(file.lastModifiedAt))
            if !file.isDirectory, !isTrashed {
                favoriteRow
            }
        }
    }

    /// Emplacement du fichier depuis la racine du drive.
    private func locationRow(_ path: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Emplacement")
                .foregroundStyle(.secondary)
            Spacer()
            Text(path)
                .font(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    private var favoriteRow: some View {
        Button {
            isFavorite.toggle()
            onToggleFavorite?()
        } label: {
            HStack {
                Text("Favori")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            if isTrashed {
                Text("Restaurer le fichier pour modifier ses tags.")
                    .foregroundStyle(.secondary)
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
                .lineLimit(1)
                .truncationMode(.tail)
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
        Section {
            Button {
                dismiss()
                onOpen()
            } label: {
                Label(file.isDirectory ? "Ouvrir le dossier" : "Ouvrir", systemImage: file.isDirectory ? "folder" : "play.fill")
            }

            if !file.isDirectory, !isTrashed {
                Button {
                    Task {
                        await FileDownloadService.shared.downloadAndShare(driveId: driveId, file: file)
                    }
                } label: {
                    Label("Télécharger", systemImage: "arrow.down.circle")
                }
            }
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
            AsyncThumbnail(driveId: driveId, fileId: file.id, isTrashed: isTrashed, shape: shape)
        }
    }

    private var folderTint: Color {
        file.color.flatMap { Color(hex: $0) }
            ?? Color(hex: defaultFolderColor)
            ?? file.fileKind.tint
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
    }

    private func dateText(_ timestamp: Double?) -> String {
        guard let ts = timestamp else { return "—" }
        let date = Date(timeIntervalSince1970: ts)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadFileInfo() async {
        guard !isTrashed else {
            // Sans réseau inutile : la liste fournit déjà le chemin quand l'API le renvoie.
            filePath = file.path
            return
        }
        filePath = file.path
        await CategoryLibrary.shared.ensureLoaded(for: driveId)
        let byId = CategoryLibrary.shared.categories(for: driveId)
        // Les listes (`with=is_favorite,categories,path`) fournissent déjà les
        // catégories, le favori et le chemin : la fiche s'affiche sans appel
        // réseau. Seule la recherche par tag (qui ne renvoie pas les
        // catégories) déclenche la fiche individuelle.
        if let categories = file.categories {
            appliedCategories = categories.compactMap { byId[$0.categoryId] }
            isFavorite = file.isFavorite == true
            return
        }
        if let info = try? await service.fileInfo(driveId: driveId, fileId: file.id) {
            appliedCategories = (info.categories ?? []).compactMap { byId[$0.categoryId] }
            isFavorite = info.isFavorite == true
            if let infoPath = info.path, !infoPath.isEmpty {
                filePath = infoPath
            }
        } else {
            // Repli : les catégories éventuellement fournies par la liste.
            appliedCategories = (file.categories ?? []).compactMap { byId[$0.categoryId] }
        }
    }
}

/// Charge une miniature de manière asynchrone pour un affichage ponctuel.
private struct AsyncThumbnail<S: InsettableShape>: View {
    let driveId: Int
    let fileId: Int
    var isTrashed = false
    let shape: S

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
        .task {
            // Clé canonique partagée avec les grilles : même image servie
            // depuis le cache au lieu d'un second téléchargement.
            image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: fileId, isTrashed: isTrashed)
        }
    }
}
