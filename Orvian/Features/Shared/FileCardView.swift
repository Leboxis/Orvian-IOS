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
        .overlay {
            if enabled {
                CardInteraction(
                    previewImage: hasQuickPreview ? thumbnail : nil,
                    previewName: file.name,
                    menuItems: menuItems,
                    onTap: {
                        if selectionMode {
                            onToggleSelection?()
                        } else {
                            action()
                        }
                    },
                    // Micro-pas C (Jev) : tap sur l'aperçu détaché = ouverture.
                    onCommit: {
                        if !selectionMode {
                            action()
                        }
                    }
                )
                // Micro-pas A (Jev) : force pleine taille. Un UIViewRepresentable
                // sans taille intrinsèque retombe à 0×0, le highlight n'aurait
                // alors aucune zone à animer.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer des favoris")
            .padding(7)
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
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        context.coordinator.parent = self
        uiView.onTap = { [weak coordinator = context.coordinator] in coordinator?.parent.onTap() }
        uiView.previewImage = previewImage
    }

    /// Vue transparente pleine taille : tap court = ouverture, long-press =
    /// menu contextuel avec aperçu. `UIContextMenuInteraction` gère les deux.
    final class InteractionView: UIView {
        var onTap: (() -> Void)?
        /// Miniature rejouée pour le highlight. Vue cachée, carrée en haut,
        /// même géométrie que la vignette SwiftUI : sans elle le système
        /// snapshotterait une vue transparente (animation depuis du vide).
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
            UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: { [weak self] in
                    guard let self, let image = self.parent.previewImage else { return nil }
                    // Micro-pas B (Jev) : taille bornée, ratio préservé.
                    let preview = QuickLookPreviewViewController(image: image, fileName: self.parent.previewName)
                    preview.preferredContentSize = self.previewSize(for: image, in: interaction)
                    return preview
                },
                actionProvider: { [weak self] _ in
                    guard let self else { return nil }
                    return self.buildMenu()
                }
            )
        }

        // Micro-pas A (Jev) : highlight seul. Le lift part de la vignette
        // carrée, coins arrondis DS.cardRadius, fond clear. Aucun changement
        // de taille d'aperçu, de tap, ni de VoiceOver dans ce pas.
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

        /// Micro-pas C (Jev) : tap sur l'aperçu détaché = ouverture du fichier
        /// (pattern Fichiers.app). En mode sélection, pas d'ouverture.
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

        /// Micro-pas B (Jev) : taille de l'aperçu détaché, ratio préservé,
        /// bornée à ~85 % largeur et ~62 % hauteur d'écran (+ légende).
        /// Sans `preferredContentSize`, le platter système tombe sur une
        /// taille petite et imprévisible.
        private func previewSize(for image: UIImage, in interaction: UIContextMenuInteraction) -> CGSize {
            let screenBounds = interaction.view?.window?.windowScene?.screen.bounds
                ?? UIScreen.main.bounds
            let maxWidth = min(screenBounds.width * 0.85, 420)
            let maxHeight = screenBounds.height * 0.62
            // 6pt image→légende + 20pt légende + 8pt marge basse : le nom
            // long reste dans le cadre avec "..." visible, sans flotter en paysage.
            let captionHeight: CGFloat = 34
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

/// Aperçu rapide : image agrandie sur fond noir avec nom en légende.
/// Le tap sur l'aperçu ouvre le fichier (commit géré par le coordinateur).
private final class QuickLookPreviewViewController: UIViewController {
    private let image: UIImage
    private let fileName: String

    private let imageView = UIImageView()
    private let nameLabel = UILabel()

    init(image: UIImage, fileName: String) {
        self.image = image
        self.fileName = fileName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Micro-pas B (Jev) : fond noir style Fichiers.app, légende blanche
        // lisible en clair comme en sombre. Indissociable de la taille fixe.
        view.backgroundColor = .black

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        imageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.text = fileName
        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(nameLabel)

        // Marges latérales + basse : sans elles un nom long touche les bords
        // arrondis du platter et sort du cadre sans "..." visible.
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: nameLabel.topAnchor, constant: -6),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            nameLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            nameLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
}

