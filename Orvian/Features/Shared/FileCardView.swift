import SwiftUI
import UIKit

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
    /// Affiche l'étoile de favori sur la miniature, avec retrait au tap. La
    /// préférence globale `showFavoriteStars` est déjà résolue par la grille.
    var showsFavoriteBadge = true
    /// Préférence globale : conserve le type comme repère lorsque le poids est masqué.
    /// Lue par la grille et transmise : une carte sur 150 n'a plus à observer
    /// elle-même les Réglages.
    var showFileSizes = true
    /// Couleur de repli des dossiers sans couleur API, lue par la grille.
    var defaultFolderColor = "#4285F5"
    var presentation = FilePresentation.grid
    var showsListMetadata = true
    var onToggleSelection: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onMove: (() -> Void)?
    /// Demande d'ouverture d'une feuille/alerte gérée par la grille parente.
    var onPresent: ((Intent) -> Void)?
    var onPrepareDetails: (() -> Void)?
    var action: () -> Void

    @State private var thumbnail: UIImage?
    @State private var thumbnailLoaded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var kind: FileKind { file.fileKind }

    /// Les réessais espacés servent uniquement aux aperçus encore générés
    /// après un import. Un ancien fichier sans miniature est mis en cache
    /// négatif dès le premier échec.
    private var shouldRetryThumbnail: Bool {
        guard let addedAt = file.addedAt else { return false }
        let age = Date().timeIntervalSince1970 - addedAt
        return age >= 0 && age <= 5 * 60
    }

    /// Teinte de la carte : couleur du dossier fournie par l'API si présente,
    /// sinon la teinte par type.
    private var tint: Color {
        file.color.flatMap { Color(hex: $0) } ?? (file.isDirectory
            ? Color(hex: defaultFolderColor) ?? kind.tint
            : kind.tint)
    }

    /// Contenu du menu contextuel, reconstruit pour `UIMenu` : la carte n'a
    /// plus de bouton englobant (l'interaction UIKit porte tap et long-press),
    /// les actions restent strictement identiques à l'ancien menu SwiftUI.
    private var menuItems: [CardMenuItem] {
        guard !selectionMode else { return [] }
        var items: [CardMenuItem] = [
            CardMenuItem(title: "Détails", systemImage: "info.circle", waitsForDismissal: true,
                         prepare: onPrepareDetails) { onPresent?(.details) }
        ]
        if !isTrashed {
            if file.isDirectory, onPresent != nil {
                items.append(CardMenuItem(title: "Changer la couleur", systemImage: "paintpalette") { onPresent?(.colorPicker) })
            }
            if !file.isDirectory {
                items.append(CardMenuItem(title: "Télécharger", systemImage: "arrow.down.circle") {
                    Task { await FileDownloadService.shared.downloadAndShare(driveId: driveId, file: file) }
                })
            }
            items.append(CardMenuItem(title: "Tags", systemImage: "tag") { onPresent?(.tags) })
            items.append(CardMenuItem(
                title: file.isFavorite == true ? "Retirer des favoris" : "Ajouter aux favoris",
                systemImage: file.isFavorite == true ? "star.slash" : "star"
            ) { onToggleFavorite?() })
            if onPresent != nil {
                items.append(CardMenuItem(title: "Renommer", systemImage: "pencil") { onPresent?(.rename) })
            }
            if onMove != nil {
                items.append(CardMenuItem(title: "Déplacer", systemImage: "folder") { onMove?() })
            }
            if onPresent != nil {
                items.append(CardMenuItem(title: "Supprimer", systemImage: "trash", destructive: true) { onPresent?(.deleteConfirm) })
            }
        }
        return items
    }

    var body: some View {
        cardContent
        .opacity(enabled ? 1 : 0.55)
        .contentShape(Rectangle())
        // Interaction (tap + long-press) portée par UIKit : `contextMenu`
        // SwiftUI n'offre plus de contrôle fin depuis iOS 16. Appui long =
        // menu seul, sans aperçu détaché (fonctionnalité retirée).
        .overlay {
            if enabled {
                CardInteraction(
                    menuItems: menuItems,
                    label: file.name,
                    value: accessibilityValue,
                    isSelected: selectionMode && isSelected,
                    onTap: {
                        if selectionMode {
                            onToggleSelection?()
                        } else {
                            action()
                        }
                    }
                )
                // Pleine taille obligatoire : un UIViewRepresentable sans taille
                // intrinsèque retombe à 0×0 et le menu n'a plus d'ancrage.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // L'étoile favori et la coche sont dessinées APRÈS l'interaction :
        // elles sont au-dessus dans l'ordre de hit-test, leurs touches ne
        // passent jamais par la vue UIKit.
        .overlay(alignment: .topTrailing) {
            if selectionMode {
                selectionBadge
            } else if showsFavoriteBadge {
                favoriteBadge
            }
        }
        .task(id: file.id) {
            await loadThumbnail()
        }
    }

    // MARK: - Zones

    @ViewBuilder private var cardContent: some View {
        if presentation == .list {
            HStack(spacing: 12) {
                thumbnailArea.overlay { playBadge }.frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).font(.body)
                        .lineLimit(1).truncationMode(.middle)
                    Text(!showsListMetadata && showFileSizes && !file.isDirectory ? "\(kind.label) · \(subtitle)" : kind.label)
                        .font(.caption).foregroundStyle(.secondary)
                    let names = (file.categories ?? []).compactMap { categoriesById[$0.categoryId]?.name }
                    if !names.isEmpty {
                        Text(names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsListMetadata {
                    VStack(alignment: .trailing, spacing: 4) {
                        if showFileSizes && !file.isDirectory { Text(subtitle) }
                        if let date = file.updatedAt ?? file.lastModifiedAt {
                            Text(Date(timeIntervalSince1970: date), format: .dateTime.day().month().year())
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).padding(.trailing, 32)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: DS.compactRadius))
            .accessibilityHidden(enabled)
        } else {
            VStack(spacing: 5) {
                thumbnailArea.overlay { playBadge }.accessibilityHidden(true)
                CardNameLayout {
                    Text(file.name)
                    .font(.footnote)
                    .lineLimit(1, reservesSpace: true)
                    .truncationMode(.middle).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity).accessibilityHidden(enabled)
                }
                .clipped()
                HStack(spacing: 4) { Text(subtitle); categoryDots }
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).accessibilityHidden(enabled)
            }
        }
    }

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
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if thumbnailLoaded {
                // Fichier sans miniature : vignette typée, teinte très légère.
                ZStack {
                    Rectangle().fill(tint.opacity(0.10))
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(tint)
                        .padding(14)
                }
                .transition(.opacity)
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
                .transition(.opacity)
            }
        }
        // L'animation est portée par le conteneur, pas par l'image : ce sont
        // les deux branches qui s'échangent qu'il faut estomper. Sur un scroll
        // rapide, la substitution instantanée scintillait.
        .animation(Motion.animation(.easeOut(duration: 0.2)), value: thumbnail != nil)
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

    /// Étoile de favori posée directement sur la miniature, sans pastille ni
    /// contour : une ombre portée suffit à la détacher des fonds clairs.
    @ViewBuilder
    private var favoriteBadge: some View {
        if file.isFavorite == true {
            Button {
                onToggleFavorite?()
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.75), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer des favoris")
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
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        let names = (file.categories ?? []).compactMap { categoriesById[$0.categoryId]?.name }
        var values = [subtitle, file.isFavorite == true ? "Favori" : "",
                 selectionMode ? (isSelected ? "Sélectionné" : "Non sélectionné") : ""]
            + names
        if presentation == .list, let date = file.updatedAt ?? file.lastModifiedAt {
            values.append("Modifié le " + Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .omitted))
        }
        return values.filter { !$0.isEmpty }.joined(separator: ", ")
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
        if let cached = ThumbnailProvider.shared.cachedMemoryThumbnail(
            driveId: driveId,
            fileId: file.id,
            isTrashed: isTrashed
        ) {
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
            includeImmediateAttempt: false,
            shouldRetry: shouldRetryThumbnail
        ) {
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
        guard !Task.isCancelled else { return }
        thumbnailLoaded = true
    }
}

/// A proportional inset without a GeometryReader or per-card measurement state.
/// The title uses 95% of its own card, regardless of screen or grid density.
struct CardNameLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let title = subviews.first else { return .zero }
        let width: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            width = max(0, proposedWidth)
        } else {
            width = title.sizeThatFits(.unspecified).width / 0.95
        }
        let size = title.sizeThatFits(ProposedViewSize(width: width * 0.95, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                             proposal: ProposedViewSize(width: bounds.width * 0.95, height: bounds.height))
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


/// Keeps a structural presentation behind the native menu's dismissal.
@MainActor
final class ContextMenuDismissal {
    private var isActive = false
    private var pending: (() -> Void)?

    func begin() { isActive = true; pending = nil }

    func perform(_ action: @escaping () -> Void) {
        if isActive { pending = action } else { action() }
    }

    func complete() {
        isActive = false
        let action = pending
        pending = nil
        action?()
    }
}

/// Élément de menu reconstruit pour `UIMenu` : titre, icône et action.
private struct CardMenuItem {
    let title: String
    let systemImage: String
    let destructive: Bool
    let waitsForDismissal: Bool
    let prepare: (() -> Void)?
    let action: () -> Void

    init(title: String, systemImage: String, destructive: Bool = false,
         waitsForDismissal: Bool = false, prepare: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.destructive = destructive
        self.waitsForDismissal = waitsForDismissal
        self.prepare = prepare
        self.action = action
    }
}

/// Interaction UIKit : tap = ouverture, long-press = menu seul (sans aperçu).
/// Remplace l'ancien `Button` + `contextMenu` SwiftUI qui offrait moins de
/// contrôle sur le tap depuis iOS 16.
private struct CardInteraction: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let menuItems: [CardMenuItem]
    let label: String
    let value: String
    let isSelected: Bool
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onTap = { [weak coordinator = context.coordinator] in coordinator?.parent.onTap() }
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        context.coordinator.parent = self
        uiView.onTap = { [weak coordinator = context.coordinator] in coordinator?.parent.onTap() }
        uiView.accessibilityLabel = label
        uiView.isEnabled = isEnabled
        uiView.accessibilityValue = value
        uiView.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        uiView.accessibilityCustomActions = (isEnabled ? menuItems : []).map { item in
            UIAccessibilityCustomAction(name: item.title) { _ in item.prepare?(); item.action(); return true }
        }
    }

    /// Vue transparente pleine taille : tap court = ouverture, long-press =
    /// menu contextuel sans aperçu. `UIContextMenuInteraction` gère les deux.
    final class InteractionView: UIButton {
        var onTap: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = true
            addTarget(self, action: #selector(handleTap), for: .primaryActionTriggered)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func accessibilityActivate() -> Bool {
            guard isEnabled else { return false }
            onTap?()
            return true
        }

        override var isHighlighted: Bool {
            didSet { backgroundColor = .clear }
        }

        @objc private func handleTap() {
            guard isEnabled else { return }
            onTap?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: CardInteraction
        private let dismissal = ContextMenuDismissal()

        init(parent: CardInteraction) {
            self.parent = parent
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard (interaction.view as? UIControl)?.isEnabled == true else { return nil }
            dismissal.begin()
            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: nil,
                actionProvider: { [weak self] _ in
                    guard let self else { return nil }
                    return self.buildMenu()
                }
            )
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            transparentPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            transparentPreview(for: interaction)
        }

        private func transparentPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.shadowPath = UIBezierPath()
            return UITargetedPreview(view: view, parameters: parameters)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            // Opening an inspector resizes the card's navigation column.
            // Wait until UIKit has finished using that card as its menu anchor.
            let finish = { [dismissal] in dismissal.complete() }
            if let animator { animator.addCompletion(finish) }
            else { DispatchQueue.main.async(execute: finish) }
        }

        private func buildMenu() -> UIMenu {
            let actions = parent.menuItems.map { item in
                UIAction(
                    title: item.title,
                    image: UIImage(systemName: item.systemImage),
                    attributes: item.destructive ? .destructive : []
                ) { [dismissal] _ in
                    item.prepare?()
                    if item.waitsForDismissal { dismissal.perform(item.action) }
                    else { item.action() }
                }
            }
            return UIMenu(title: "", children: actions)
        }
    }
}

