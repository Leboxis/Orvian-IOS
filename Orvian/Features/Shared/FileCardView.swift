import SwiftUI

/// Carte de fichier : miniature, étoile favori, nom, taille.
/// Tap → ouverture du fichier/dossier. Appui long → menu contextuel
/// (détails, favori, renommer, supprimer).
struct FileCardView: View {
    let file: DriveFile
    let driveId: Int
    var enabled = true
    /// Mode sélection (corbeille) : le tap coche au lieu d'ouvrir.
    var selectionMode = false
    /// Fichier corbeillé : les miniatures passent par l'endpoint trash et
    /// les actions favori/renommer/supprimer sont masquées.
    var isTrashed = false
    /// État de la coche en mode sélection.
    var isSelected = false
    var onToggleSelection: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRename: ((String) -> Void)?
    var action: () -> Void

    @State private var thumbnail: UIImage?
    @State private var thumbnailLoaded = false
    @State private var showDetail = false
    @State private var showDeleteConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private var kind: FileKind { file.fileKind }

    /// Teinte de la carte : couleur du dossier fournie par l'API si présente,
    /// sinon la teinte par type.
    private var tint: Color {
        file.color.flatMap { Color(hex: $0) } ?? kind.tint
    }

    var body: some View {
        Button {
            if selectionMode {
                onToggleSelection?()
            } else {
                action()
            }
        } label: {
            VStack(spacing: 5) {
                thumbnailArea
                    .overlay(alignment: .topTrailing) {
                        if selectionMode {
                            selectionBadge
                        } else {
                            favoriteBadge
                        }
                    }
                    .overlay(alignment: .center) { playBadge }
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                Text(file.name)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Text(subtitle)
                    categoryDots
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
            }
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .contextMenu {
            if !selectionMode {
                Button {
                    showDetail = true
                } label: {
                    Label("Détails", systemImage: "info.circle")
                }
                if !isTrashed {
                    Button {
                        onToggleFavorite?()
                    } label: {
                        Label(
                            file.isFavorite == true ? "Retirer des favoris" : "Ajouter aux favoris",
                            systemImage: file.isFavorite == true ? "star.slash" : "star"
                        )
                    }
                    if onRename != nil {
                        Button {
                            renameText = file.name
                            showRenameAlert = true
                        } label: {
                            Label("Renommer", systemImage: "pencil")
                        }
                    }
                    if onDelete != nil {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showDetail) {
            FileDetailSheet(
                file: file,
                driveId: driveId,
                isTrashed: isTrashed,
                onOpen: action,
                onToggleFavorite: onToggleFavorite,
                onDelete: onDelete,
                onRename: onRename
            )
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
        .task(id: file.id) {
            await loadThumbnail()
        }
    }

    // MARK: - Zones

    /// Conteneur carré strict : `Color.clear` fixe les limites, le contenu
    /// est plaqué dessus en remplissage puis recadré — toutes les cartes
    /// ont exactement la même taille, quelle que soit l'orientation
    /// d'origine de la miniature (le serveur renvoie toujours du 4:3).
    private var thumbnailArea: some View {
        let shape = RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.black.opacity(0.05), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else if thumbnailLoaded {
            // Fichier sans miniature : vignette typée, teinte très légère.
            ZStack {
                Rectangle().fill(tint.opacity(0.10))
                Image(systemName: kind.symbolName)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(tint)
                    .padding(14)
            }
        } else {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.5))
                if kind == .folder {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(tint.opacity(0.8))
                        .padding(14)
                }
            }
        }
    }

    private var subtitle: String {
        if file.isDirectory { return "Dossier" }
        return ByteFormatter.string(fromBytes: file.size)
    }

    /// Petits cercles de la couleur de chaque catégorie (tag) du fichier,
    /// discrètement à droite du poids. Maximum 4 pour rester léger.
    @ViewBuilder
    private var categoryDots: some View {
        let hexes = (file.categories ?? []).compactMap { $0.category?.color }
        ForEach(hexes.prefix(4), id: \.self) { hex in
            if let color = Color(hex: hex) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
        }
    }

    /// Pastille translucide + étoile, lisible sur toute miniature.
    @ViewBuilder
    private var favoriteBadge: some View {
        if file.isFavorite == true {
            Button {
                onToggleFavorite?()
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer des favoris")
            .padding(5)
        }
    }

    /// Cocher de sélection (mode sélection de la corbeille).
    @ViewBuilder
    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : .white)
            .shadow(color: .black.opacity(isSelected ? 0 : 0.35), radius: 3, y: 1)
            .padding(5)
    }

    /// Indicateur de lecture sur les vidéos.
    @ViewBuilder
    private var playBadge: some View {
        if file.isVideo {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        }
    }

    // MARK: - Miniature

    private func loadThumbnail() async {
        guard kind.supportsThumbnail else {
            thumbnailLoaded = true
            return
        }
        // Accès mémoire synchrone immédiat (zéro délai, zéro animation superflue)
        if let cached = ThumbnailProvider.shared.cachedMemoryThumbnail(driveId: driveId, fileId: file.id) {
            thumbnail = cached
            thumbnailLoaded = true
            return
        }
        if let image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, isTrashed: isTrashed) {
            guard !Task.isCancelled else { return }
            thumbnail = image
            thumbnailLoaded = true
        } else {
            thumbnailLoaded = true
        }
    }
}

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

    @Environment(\.dismiss) private var dismiss
    @State private var categories: [Category] = []
    @State private var appliedCategoryIds: Set<Int>
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
        onRename: ((String) -> Void)?
    ) {
        self.file = file
        self.driveId = driveId
        self.isTrashed = isTrashed
        self.onOpen = onOpen
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.onRename = onRename
        _appliedCategoryIds = State(initialValue: Set((file.categories ?? []).compactMap { $0.category?.id }))
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
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ellipsisMenu
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
            .task { await loadCategories() }
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
            labeledRow("Ajouté", dateText(file.addedAt))
            labeledRow("Modifié", dateText(file.lastModifiedAt))
            if !file.isDirectory, !isTrashed {
                favoriteRow
            }
        }
    }

    private var favoriteRow: some View {
        Button {
            onToggleFavorite?()
        } label: {
            HStack {
                Text("Favori")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: file.isFavorite == true ? "star.fill" : "star")
                    .foregroundStyle(file.isFavorite == true ? .yellow : .secondary)
            }
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            if isTrashed {
                Text("Restaurer le fichier pour modifier ses tags.")
                    .foregroundStyle(.secondary)
            } else if categories.isEmpty {
                Text("Aucun tag disponible")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categories) { category in
                    categoryRow(category)
                }
            }
        }
    }

    private func categoryRow(_ category: Category) -> some View {
        Button {
            Task { await toggleCategory(category) }
        } label: {
            HStack {
                Circle()
                    .fill(Color(hex: category.color) ?? .gray)
                    .frame(width: 10, height: 10)
                Text(category.name)
                    .foregroundStyle(.primary)
                Spacer()
                if appliedCategoryIds.contains(category.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var openSection: some View {
        Section {
            Button {
                dismiss()
                onOpen()
            } label: {
                Label(file.isDirectory ? "Ouvrir le dossier" : "Ouvrir", systemImage: file.isDirectory ? "folder" : "play.fill")
            }
        }
    }

    private var ellipsisMenu: some View {
        Menu {
            if !isTrashed, let onToggleFavorite {
                Button {
                    onToggleFavorite()
                } label: {
                    Label(
                        file.isFavorite == true ? "Retirer des favoris" : "Ajouter aux favoris",
                        systemImage: file.isFavorite == true ? "star.slash" : "star"
                    )
                }
            }
            if !isTrashed, onRename != nil {
                Button {
                    renameText = file.name
                    showRenameAlert = true
                } label: {
                    Label("Renommer", systemImage: "pencil")
                }
            }
            if !isTrashed, onDelete != nil {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var thumbnailPreview: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if file.isDirectory {
            ZStack {
                Rectangle().fill((file.color.flatMap { Color(hex: $0) } ?? file.fileKind.tint).opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(file.color.flatMap { Color(hex: $0) } ?? file.fileKind.tint)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
        } else {
            AsyncThumbnail(driveId: driveId, fileId: file.id, isTrashed: isTrashed, shape: shape)
        }
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

    private func loadCategories() async {
        if let cats = try? await service.categories(driveId: driveId) {
            categories = cats
        }
    }

    private func toggleCategory(_ category: Category) async {
        let isApplying = !appliedCategoryIds.contains(category.id)
        if isApplying {
            appliedCategoryIds.insert(category.id)
        } else {
            appliedCategoryIds.remove(category.id)
        }
        do {
            if isApplying {
                try await service.addCategory(driveId: driveId, fileId: file.id, categoryId: category.id)
                TagUsageStore.markUsed(driveId: driveId, categoryId: category.id)
            } else {
                try await service.removeCategory(driveId: driveId, fileId: file.id, categoryId: category.id)
            }
        } catch {
            if isApplying {
                appliedCategoryIds.remove(category.id)
            } else {
                appliedCategoryIds.insert(category.id)
            }
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
            image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: fileId, pixels: 200, isTrashed: isTrashed)
        }
    }
}
