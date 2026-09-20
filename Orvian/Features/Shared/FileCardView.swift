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
    /// Affiche l'étoile de favori sur la miniature (sous réserve de la
    /// préférence globale `showFavoriteStars`), avec retrait au tap.
    var showsFavoriteBadge = true
    var onToggleSelection: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onMove: (() -> Void)?
    /// Demande d'ouverture d'une feuille/alerte gérée par la grille parente.
    var onPresent: ((Intent) -> Void)?
    var action: () -> Void

    /// Préférence globale : conserve le type comme repère lorsque le poids est masqué.
    @AppStorage("showFileSizes") private var showFileSizes = true
    /// Préférence globale : affiche ou masque l'étoile des favoris sur les cartes.
    @AppStorage("showFavoriteStars") private var showFavoriteStars = true
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"
    @State private var thumbnail: UIImage?
    @State private var thumbnailLoaded = false

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

    /// Les fichiers média ont droit à un vrai aperçu détaché au long-press
    /// (pattern Fichiers.app), les dossiers et documents gardent le menu simple.
    private var hasQuickPreview: Bool {
        !file.isDirectory && (file.isImage || file.isGIF || file.isVideo)
    }

    /// Contenu du menu contextuel, reconstruit pour `UIMenu` : la carte n'a
    /// plus de bouton englobant (l'interaction UIKit porte tap et long-press),
    /// les actions restent strictement identiques à l'ancien menu SwiftUI.
    private var menuItems: [CardMenuItem] {
        guard !selectionMode else { return [] }
        var items: [CardMenuItem] = [
            CardMenuItem(title: "Détails", systemImage: "info.circle") { onPresent?(.details) }
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
        VStack(spacing: 5) {
            thumbnailArea
                .overlay(alignment: .center) { playBadge }
                .overlay(alignment: .bottomLeading) { gifBadge }

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
        // Interaction (tap + long-press) portée par UIKit : seul
        // `UIContextMenuInteraction` offre l'aperçu détaché au-dessus du menu
        // (pattern Fichiers.app) — SwiftUI l'a retiré de `contextMenu`.
        // L'overlay est forcé pleine taille : un UIViewRepresentable sans
        // taille intrinsèque retomberait sinon à 0×0 (aucune zone tactile).
        .overlay {
            if enabled {
                CardInteraction(
                    previewImage: hasQuickPreview ? thumbnail : nil,
                    previewName: file.name,
                    previewSubtitle: subtitle,
                    previewIsVideo: file.isVideo,
                    previewIsGIF: file.isGIF,
                    accessibilityLabel: file.name,
                    menuItems: menuItems,
                    onTap: {
                        if selectionMode {
                            onToggleSelection?()
                        } else {
                            action()
                        }
                    },
                    onCommit: {
                        if !selectionMode {
                            action()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
            }
        }
        // L'étoile favori et la coche sont dessinées APRÈS l'interaction :
        // elles sont au-dessus dans l'ordre de hit-test, leurs touches ne
        // passent jamais par la vue UIKit.
        .overlay(alignment: .topTrailing) {
            if selectionMode {
                selectionBadge
            } else if showsFavoriteBadge && showFavoriteStars {
                favoriteBadge
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

    /// Étoile de favori sur pastille givrée : lisible sur miniature claire
    /// comme sombre, sans masquer l'image.
    @ViewBuilder
    private var favoriteBadge: some View {
        if file.isFavorite == true {
            Button {
                onToggleFavorite?()
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer des favoris")
            .padding(10)
            .contentShape(Rectangle())
        }
    }

    /// Cocher de sélection (mode sélection de la corbeille) : pastille
    /// givrée à l'état vide pour rester visible sur fond clair.
    @ViewBuilder
    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : .white)
            .padding(4)
            .background {
                if !isSelected {
                    Circle().fill(.ultraThinMaterial)
                }
            }
            .shadow(color: .black.opacity(isSelected ? 0 : 0.35), radius: 3, y: 1)
            .padding(8)
            .contentShape(Rectangle())
    }

    /// Indicateur de lecture sur les vidéos.
    @ViewBuilder
    private var playBadge: some View {
        if file.isVideo {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.9)
                }
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        }
    }

    /// Pastille « GIF » en bas de la vignette : distingue les animés des
    /// images fixes d'un coup d'œil.
    @ViewBuilder
    private var gifBadge: some View {
        if file.isGIF {
            Text("GIF")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.7)
                }
                .padding(7)
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


/// Élément de menu reconstruit pour `UIMenu` : titre, icône SF Symbol,
/// style destructeur optionnel. Permet de conserver le menu complet de la
/// carte dans le même geste que l'aperçu détaché.
private struct CardMenuItem {
    let title: String
    let systemImage: String
    let destructive: Bool
    let action: () -> Void

    init(title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.destructive = destructive
        self.action = action
    }
}

/// Interaction UIKit portée par `UIContextMenuInteraction` : tap = ouverture,
/// long-press = aperçu détaché grand format + menu complet (pattern
/// Fichiers.app). Remplace l'ancien `Button` + `contextMenu` SwiftUI qui ne
/// permettait plus d'aperçu détaché depuis iOS 16.
private struct CardInteraction: UIViewRepresentable {
    /// Miniature en cache pour l'aperçu ; nil pour les dossiers et documents.
    let previewImage: UIImage?
    let previewName: String
    /// Légende de l'aperçu (poids ou type) + pastilles.
    let previewSubtitle: String?
    let previewIsVideo: Bool
    let previewIsGIF: Bool
    let accessibilityLabel: String
    let menuItems: [CardMenuItem]
    let onTap: () -> Void
    /// Tap sur l'aperçu détaché (commit) = ouverture du fichier.
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onTap = { [weak coordinator = context.coordinator] in coordinator?.parent.onTap() }
        view.previewImage = previewImage
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityCustomActions = menuItems.map { item in
            UIAccessibilityCustomAction(name: item.title) { _ in
                item.action()
                return true
            }
        }
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        context.coordinator.parent = self
        uiView.onTap = { [weak coordinator = context.coordinator] in coordinator?.parent.onTap() }
        uiView.previewImage = previewImage
        uiView.accessibilityLabel = accessibilityLabel
        uiView.accessibilityCustomActions = menuItems.map { item in
            UIAccessibilityCustomAction(name: item.title) { _ in
                item.action()
                return true
            }
        }
    }

    /// Vue transparente pleine taille : tap court = ouverture, long-press =
    /// menu contextuel avec aperçu. `UIContextMenuInteraction` gère les deux.
    /// La miniature est rejouée dans un `UIImageView` carré en haut (même
    /// géométrie que la vignette SwiftUI) : c'est lui qui sert de source au
    /// `UITargetedPreview` de lift/dismiss — sans cela le système
    /// snapshotterait une vue transparente (animation depuis du vide).
    final class InteractionView: UIView {
        var onTap: (() -> Void)?
        var previewImage: UIImage? {
            didSet { syncPreview() }
        }

        private let previewImageView = UIImageView()

        /// Source du highlight ; nil (dossiers/documents) → animation par défaut.
        var highlightView: UIView? {
            previewImage == nil ? nil : previewImageView
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityTraits = .button
            previewImageView.contentMode = .scaleAspectFill
            previewImageView.clipsToBounds = true
            previewImageView.layer.cornerRadius = DS.cardRadius
            previewImageView.layer.cornerCurve = .continuous
            previewImageView.isHidden = true
            previewImageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(previewImageView)
            NSLayoutConstraint.activate([
                previewImageView.topAnchor.constraint(equalTo: topAnchor),
                previewImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                previewImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                previewImageView.heightAnchor.constraint(equalTo: previewImageView.widthAnchor),
            ])
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(tap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onTap?()
        }

        /// VoiceOver : le double-tap n'active pas l'UITapGestureRecognizer.
        override func accessibilityActivate() -> Bool {
            onTap?()
            return true
        }

        private func syncPreview() {
            previewImageView.image = previewImage
            previewImageView.isHidden = previewImage == nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: CardInteraction

        init(parent: CardInteraction) {
            self.parent = parent
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            // Mode sélection : le tap coche déjà, aucun menu au long-press.
            // Retourner nil désactive le long-press tout en gardant le tap.
            guard !parent.menuItems.isEmpty else { return nil }
            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: { [weak self] in
                    guard let self, let image = self.parent.previewImage else { return nil }
                    let preview = QuickLookPreviewViewController(
                        image: image,
                        fileName: self.parent.previewName,
                        subtitle: self.parent.previewSubtitle,
                        isVideo: self.parent.previewIsVideo,
                        isGIF: self.parent.previewIsGIF
                    )
                    preview.preferredContentSize = self.previewSize(for: image, in: interaction)
                    return preview
                },
                actionProvider: { [weak self] _ in
                    guard let self, !self.parent.menuItems.isEmpty else { return nil }
                    return self.buildMenu()
                }
            )
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            targetedPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            targetedPreview(for: interaction)
        }

        /// Tap sur l'aperçu détaché = ouverture du fichier (pattern Fichiers.app).
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
        ) {
            animator.addCompletion { [weak self] in
                guard let self else { return }
                self.parent.onCommit()
            }
        }

        private func targetedPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let interactionView = interaction.view as? InteractionView,
                  let highlightView = interactionView.highlightView else { return nil }
            // Le highlight peut être demandé avant le layout final.
            interactionView.layoutIfNeeded()
            highlightView.layoutIfNeeded()
            guard highlightView.bounds.width > 1, highlightView.bounds.height > 1 else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(
                roundedRect: highlightView.bounds,
                cornerRadius: DS.cardRadius
            )
            return UITargetedPreview(view: highlightView, parameters: parameters)
        }

        /// Taille de l'aperçu détaché : ratio de l'image préservé, borné à
        /// ~85 % de la largeur et ~62 % de la hauteur d'écran (+ légende
        /// deux lignes et marges). Sans `preferredContentSize`, le platter
        /// système tombe sur une taille petite et imprévisible.
        private func previewSize(for image: UIImage, in interaction: UIContextMenuInteraction) -> CGSize {
            let screenBounds = interaction.view?.window?.windowScene?.screen.bounds
                ?? UIScreen.main.bounds
            let maxWidth = min(screenBounds.width * 0.85, 420)
            let maxHeight = screenBounds.height * 0.62
            let captionHeight: CGFloat = 58
            let ratio = image.size.height / max(image.size.width, 1)
            guard ratio.isFinite, ratio > 0 else {
                return CGSize(width: maxWidth, height: min(maxHeight, maxWidth + captionHeight))
            }
            var width = maxWidth
            var height = width * ratio + captionHeight
            if height > maxHeight {
                height = maxHeight
                width = max((height - captionHeight) / max(ratio, 0.01), 200)
            }
            return CGSize(width: max(width, 200), height: max(height, 200))
        }

        private func buildMenu() -> UIMenu {
            let actions = parent.menuItems.map { item in
                UIAction(
                    title: item.title,
                    image: UIImage(systemName: item.systemImage),
                    attributes: item.destructive ? .destructive : []
                ) { _ in item.action() }
            }
            return UIMenu(title: "", children: actions)
        }
    }
}

/// Aperçu rapide, style Photos : image flottante aux coins arrondis sur
/// fond flouté de la même image, pastille givrée Vidéo/GIF, bouton
/// lecture pour les vidéos et légende nom + détails. Épuré : aucun
/// chrome superflu, même langage givré que les badges de la carte.
/// Le tap sur l'aperçu ouvre le fichier (commit géré par le coordinateur).
private final class QuickLookPreviewViewController: UIViewController {
    private let image: UIImage
    private let fileName: String
    private let subtitle: String?
    private let isVideo: Bool
    private let isGIF: Bool

    private let backdropView = UIImageView()
    private let imageView = UIImageView()

    init(
        image: UIImage,
        fileName: String,
        subtitle: String? = nil,
        isVideo: Bool = false,
        isGIF: Bool = false
    ) {
        self.image = image
        self.fileName = fileName
        self.subtitle = subtitle
        self.isVideo = isVideo
        self.isGIF = isGIF
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Même image en remplissage flouté : plus de bandes noires vides
        // sur les panoramas et portraits, rendu plein et lumineux.
        backdropView.image = image
        backdropView.contentMode = .scaleAspectFill
        backdropView.clipsToBounds = true
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)
        let dim = UIView()
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        dim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 14
        imageView.layer.cornerCurve = .continuous
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        if isVideo || isGIF {
            let pill = makePill(text: isVideo ? "Vidéo" : "GIF", systemIcon: isVideo ? "play.fill" : nil)
            view.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 10),
                pill.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 10),
            ])
        }
        if isVideo {
            let play = makePlayButton()
            play.isUserInteractionEnabled = false
            view.addSubview(play)
            NSLayoutConstraint.activate([
                play.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                play.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                play.widthAnchor.constraint(equalToConstant: 60),
                play.heightAnchor.constraint(equalToConstant: 60),
            ])
        }

        let caption = UIStackView()
        caption.axis = .vertical
        caption.alignment = .center
        caption.spacing = 2
        caption.translatesAutoresizingMaskIntoConstraints = false
        let nameLabel = UILabel()
        nameLabel.text = fileName
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        caption.addArrangedSubview(nameLabel)
        if let subtitle, !subtitle.isEmpty {
            let detailLabel = UILabel()
            detailLabel.text = subtitle
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = UIColor.white.withAlphaComponent(0.65)
            detailLabel.textAlignment = .center
            caption.addArrangedSubview(detailLabel)
        }
        view.addSubview(caption)

        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            imageView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -10),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            caption.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    /// Pastille flottante givrée (type de média) : même langage que les
    /// badges de la carte, adoucie — flou sombre, contour fin discret.
    private func makePill(text: String, systemIcon: String?) -> UIView {
        let container = UIView()
        container.layer.cornerRadius = 11
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = 0.7
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blur)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let systemIcon, let iconImage = UIImage(systemName: systemIcon) {
            let icon = UIImageView(image: iconImage)
            icon.tintColor = .white
            icon.contentMode = .scaleAspectFit
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 9),
                icon.heightAnchor.constraint(equalToConstant: 9),
            ])
            stack.addArrangedSubview(icon)
        }
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        stack.addArrangedSubview(label)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
        ])
        return container
    }

    /// Bouton lecture givré (vidéos), purement indicatif : tout tap
    /// sur l'aperçu ouvre le fichier.
    private func makePlayButton() -> UIView {
        let container = UIView()
        container.layer.cornerRadius = 30
        container.layer.borderWidth = 0.9
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blur)
        let icon = UIImageView(image: UIImage(systemName: "play.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        return container
    }
}

