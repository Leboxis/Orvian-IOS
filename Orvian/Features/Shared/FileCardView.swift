import SwiftUI

/// Carte de fichier : miniature, étoile favori, nom et informations secondaires.
/// Tap → ouverture du fichier/dossier. Appui long → menu contextuel
/// (détails, couleur pour les dossiers, télécharger, tags, favori,
/// renommer, déplacer, supprimer).
struct FileCardView: View {
    let file: DriveFile
    let driveId: Int
    /// Index id → catégorie du drive, pour les pastilles de tags des cartes
    /// (l'API ne renvoie que des `categoryId` dans les listes).
    var categoriesById: [Int: Category] = [:]
    var enabled = true
    /// Mode sélection : le tap coche au lieu d'ouvrir.
    var selectionMode = false
    /// Fichier corbeillé : les miniatures passent par l'endpoint trash et
    /// les actions favori/renommer/supprimer sont masquées.
    var isTrashed = false
    /// État de la coche en mode sélection.
    var isSelected = false
    /// L'étoile est redondante dans l'onglet Favoris, où chaque carte est déjà
    /// un favori. Les autres grilles la conservent comme action rapide.
    var showsFavoriteBadge = true
    var onToggleSelection: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onMove: (() -> Void)?
    /// Change la couleur d'un dossier (menu contextuel des dossiers).
    var onSetColor: ((String) -> Void)?
    /// Confirme localement un changement de tag pour rafraîchir les pastilles
    /// des cartes derrière l'éditeur.
    var onTagChanged: ((Category, Bool) -> Void)?
    var action: () -> Void

    /// Préférence globale : conserve le type comme repère lorsque le poids est masqué.
    @AppStorage("showFileSizes") private var showFileSizes = true
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"
    @State private var thumbnail: UIImage?
    @State private var thumbnailLoaded = false
    @State private var showDetail = false
    @State private var showTagsSheet = false
    @State private var showColorPicker = false
    @State private var showDeleteConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private var kind: FileKind { file.fileKind }

    /// Teinte de la carte : couleur du dossier fournie par l'API si présente,
    /// sinon la teinte par type.
    private var tint: Color {
        file.color.flatMap { Color(hex: $0) } ?? (file.isDirectory
            ? Color(hex: defaultFolderColor) ?? kind.tint
            : kind.tint)
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
                        } else if showsFavoriteBadge {
                            favoriteBadge
                        }
                    }
                    .overlay(alignment: .center) { playBadge }

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
                    if file.isDirectory, onSetColor != nil {
                        Button {
                            showColorPicker = true
                        } label: {
                            Label("Changer la couleur", systemImage: "paintpalette")
                        }
                    }
                    if !file.isDirectory {
                        Button {
                            Task {
                                await FileDownloadService.shared.downloadAndShare(driveId: driveId, file: file)
                            }
                        } label: {
                            Label("Télécharger", systemImage: "arrow.down.circle")
                        }
                    }
                    Button {
                        showTagsSheet = true
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
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
                    if onMove != nil {
                        Button {
                            onMove?()
                        } label: {
                            Label("Déplacer", systemImage: "folder")
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
                onRename: onRename,
                onMove: onMove
            )
        }
        .sheet(isPresented: $showTagsSheet) {
            TagsEditorSheet(
                driveId: driveId,
                file: file,
                onChanged: onTagChanged
            )
        }
        .sheet(isPresented: $showColorPicker) {
            FolderColorPickerSheet(
                file: file,
                onSetColor: onSetColor
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
        return showFileSizes ? ByteFormatter.string(fromBytes: file.size) : kind.label
    }

    /// Petits cercles de la couleur de chaque catégorie (tag) du fichier,
    /// discrètement à droite du poids. Maximum 4 pour rester léger.
    @ViewBuilder
    private var categoryDots: some View {
        let categories = (file.categories ?? []).compactMap { categoriesById[$0.categoryId] }
        ForEach(categories.prefix(4), id: \.id) { category in
            if let color = Color(hex: category.color) {
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
                    .background(.black.opacity(0.48), in: Circle())
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
                .background(.black.opacity(0.48), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                }
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
        if let image = await ThumbnailProvider.shared.thumbnail(
            driveId: driveId,
            fileId: file.id,
            isTrashed: isTrashed
        ) {
            guard !Task.isCancelled else { return }
            thumbnail = image
            thumbnailLoaded = true
            return
        }
        // Affiche immédiatement le remplacement, puis continue d'attendre le
        // poster vidéo sans figer un squelette pendant tout l'encodage.
        thumbnailLoaded = true
        if let image = await ThumbnailProvider.shared.thumbnailWhenAvailable(
            driveId: driveId,
            fileId: file.id,
            isTrashed: isTrashed,
            includeImmediateAttempt: false
        ) {
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
        guard !Task.isCancelled else { return }
        thumbnailLoaded = true
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
            image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: fileId, pixels: DS.thumbnailPixels, isTrashed: isTrashed)
        }
    }
}

/// Sélecteur de couleur d'un dossier (menu contextuel → « Changer la couleur »).
/// Grille des couleurs officielles de kDrive ; un tap applique la couleur
/// directement via l'API et referme la feuille.
private struct FolderColorPickerSheet: View {
    let file: DriveFile
    let onSetColor: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedColor: String?

    /// Palette officielle de l'application kDrive.
    private static let palette = [
        "#9f9f9f", "#F44336", "#E91E63", "#9C26B0",
        "#673AB7", "#4051B5", "#4BAF50", "#009688",
        "#00BCD4", "#02A9F4", "#2196F3", "#8BC34A",
        "#CDDC3A", "#FFC10A", "#FF9802", "#607D8B",
        "#795548",
    ]

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Self.palette, id: \.self) { hex in
                        colorSwatch(hex)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("Couleur du dossier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .onAppear {
            selectedColor = file.color
        }
    }

    /// Pastille ronde de couleur, avec coche sur la couleur actuelle.
    private func colorSwatch(_ hex: String) -> some View {
        let isSelected = selectedColor?.lowercased() == hex.lowercased()
        return Button {
            selectedColor = hex
            onSetColor?(hex)
            dismiss()
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 48, height: 48)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                    }
                }
                .overlay {
                    Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Couleur \(hex)")
    }
}
