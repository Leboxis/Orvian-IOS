import SwiftUI

/// Carte de fichier : miniature, étoile favori, nom et informations secondaires.
/// Tap → ouverture du fichier/dossier. Appui long → menu contextuel
/// (détails, couleur pour les dossiers, télécharger, tags, favori,
/// renommer, déplacer, supprimer). Les feuilles et alertes issues de ce menu
/// sont montées une seule fois par la grille parente : la carte émet une
/// demande (`onPresent`), ce qui évite de porter ces modificateurs sur
/// chaque carte du view-graph.
struct FileCardView: View {
    /// Actions du menu contextuel dont la présentation est portée par la grille.
    enum Intent {
        case details
        case colorPicker
        case tags
        case rename
        case deleteConfirm
    }

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
    var onMove: (() -> Void)?
    /// Demande d'ouverture d'une feuille/alerte gérée par la grille parente.
    var onPresent: ((Intent) -> Void)?
    var action: () -> Void

    /// Préférence globale : conserve le type comme repère lorsque le poids est masqué.
    @AppStorage("showFileSizes") private var showFileSizes = true
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: UIImage?
    @State private var thumbnailLoaded = false

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
        .buttonStyle(FileCardPressStyle())
        .disabled(!enabled)
        .contextMenu {
            if !selectionMode {
                Button {
                    onPresent?(.details)
                } label: {
                    Label("Détails", systemImage: "info.circle")
                }
                if !isTrashed {
                    if file.isDirectory, onPresent != nil {
                        Button {
                            onPresent?(.colorPicker)
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
                        onPresent?(.tags)
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
                    if onPresent != nil {
                        Button {
                            onPresent?(.rename)
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
                    if onPresent != nil {
                        Button(role: .destructive) {
                            onPresent?(.deleteConfirm)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
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
            .contentTransition(.symbolEffect(.replace))
            .symbolEffectsRemoved(reduceMotion)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isSelected)
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

/// Retour d'appui local : ne modifie ni la grille ni ses gestes de défilement.
private struct FileCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.98 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
    }
}

/// Sélecteur de couleur d'un dossier (menu contextuel → « Changer la couleur »).
/// Grille des couleurs officielles de kDrive ; un tap applique la couleur
/// directement via l'API et referme la feuille. Présenté par la grille
/// (`FileGridView`), une seule instance pour toutes les cartes.
struct FolderColorPickerSheet: View {
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
