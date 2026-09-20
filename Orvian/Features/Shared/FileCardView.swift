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
        // Interaction (tap + long-press) portée par UIKit. L'appui long
        // ouvre l'aperçu + menu dans une fenêtre centrée sur l'écran.
        // L'overlay est forcé pleine taille : un UIViewRepresentable sans
        // taille intrinsèque retomberait sinon à 0×0 (aucune zone tactile).
        .overlay {
            if enabled {
                CardInteraction(
                    previewImage: hasQuickPreview ? thumbnail : nil,
                    previewName: file.name,
                    previewSubtitle: subtitle,
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


/// Élément de menu de la carte : titre, icône SF Symbol, style destructeur
/// optionnel. Même contenu que l'ancien menu natif, affiché dans la carte
/// d'actions de la fenêtre centrée.
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

/// Interaction UIKit : tap = ouverture, appui long = aperçu + menu centrés
/// sur l'écran (fenêtre dédiée). Le menu natif (`UIContextMenuInteraction`)
/// est positionné par le système au niveau de la carte — ni l'aperçu ni le
/// menu ne peuvent y être centrés — d'où cette fenêtre qui affiche
/// toujours la même disposition, quelle que soit la carte d'origine.
/// Remplace l'ancien `Button` + `contextMenu` SwiftUI.
private struct CardInteraction: UIViewRepresentable {
    /// Miniature en cache pour l'aperçu ; nil pour les dossiers et documents.
    let previewImage: UIImage?
    let previewName: String
    /// Légende de l'aperçu (poids ou type).
    let previewSubtitle: String?
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
        view.onLongPress = { [weak coordinator = context.coordinator] source in coordinator?.showOverlay(from: source) }
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityCustomActions = menuItems.map { item in
            UIAccessibilityCustomAction(name: item.title) { _ in
                item.action()
                return true
            }
        }
        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        context.coordinator.parent = self
        uiView.onTap = { [weak coordinator = context.coordinator] in coordinator?.parent.onTap() }
        uiView.onLongPress = { [weak coordinator = context.coordinator] source in coordinator?.showOverlay(from: source) }
        uiView.accessibilityLabel = accessibilityLabel
        uiView.accessibilityCustomActions = menuItems.map { item in
            UIAccessibilityCustomAction(name: item.title) { _ in
                item.action()
                return true
            }
        }
    }

    /// Vue transparente pleine taille : tap court = ouverture, appui long =
    /// aperçu + menu centrés (fenêtre dédiée). Le tap attend l'échec du
    /// long-press pour ne jamais s'ouvrir au relâché d'un appui long.
    final class InteractionView: UIView {
        var onTap: (() -> Void)?
        var onLongPress: ((InteractionView) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityTraits = .button
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
            longPress.minimumPressDuration = 0.45
            longPress.allowableMovement = 12
            addGestureRecognizer(longPress)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.require(toFail: longPress)
            addGestureRecognizer(tap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onTap?()
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onLongPress?(self)
        }

        /// VoiceOver : le double-tap n'active pas l'UITapGestureRecognizer.
        override func accessibilityActivate() -> Bool {
            onTap?()
            return true
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CardInteraction
        private var activeOverlay: PreviewOverlay?

        init(parent: CardInteraction) {
            self.parent = parent
        }

        /// Appui long : aperçu + menu dans une fenêtre centrée sur l'écran,
        /// identique quelle que soit la carte d'origine. En mode sélection
        /// le tap coche déjà : aucun overlay quand le menu est vide.
        func showOverlay(from sourceView: UIView) {
            guard activeOverlay == nil,
                  !parent.menuItems.isEmpty,
                  let scene = sourceView.window?.windowScene else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let overlay = PreviewOverlay(
                image: parent.previewImage,
                fileName: parent.previewName,
                subtitle: parent.previewSubtitle,
                items: parent.menuItems,
                scene: scene,
                onMediaTapped: { [weak self] in
                    guard let self else { return }
                    let commit = self.parent.onCommit
                    self.dismissOverlay(then: commit)
                },
                onItemPicked: { [weak self] item in
                    guard let self else { return }
                    let action = item.action
                    self.dismissOverlay(then: action)
                },
                onDidDismiss: { [weak self] in self?.activeOverlay = nil }
            )
            activeOverlay = overlay
            overlay.show()
        }

        private func dismissOverlay(then action: (() -> Void)? = nil) {
            activeOverlay?.dismiss(then: action)
        }
    }
}

/// Fenêtre d'aperçu + menu, toujours centrée sur l'écran : fond assombri,
/// carte média (image bord à bord, légende resserrée) puis carte d'actions.
/// Le menu natif est positionné par le système au niveau de la carte : ni
/// l'aperçu ni le menu ne peuvent y être centrés, d'où cette fenêtre dont
/// la disposition est identique quel que soit l'élément d'origine.
private final class PreviewOverlay: UIWindow {
    private let onMediaTapped: () -> Void
    private let onItemPicked: (CardMenuItem) -> Void
    private let onDidDismiss: () -> Void
    private var didDismiss = false

    private let dimView = UIButton(type: .custom)
    private let stack = UIStackView()

    init(
        image: UIImage?,
        fileName: String,
        subtitle: String?,
        items: [CardMenuItem],
        scene: UIWindowScene,
        onMediaTapped: @escaping () -> Void,
        onItemPicked: @escaping (CardMenuItem) -> Void,
        onDidDismiss: @escaping () -> Void
    ) {
        self.onMediaTapped = onMediaTapped
        self.onItemPicked = onItemPicked
        self.onDidDismiss = onDidDismiss
        super.init(windowScene: scene)

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.accessibilityViewIsModal = true
        rootViewController = root
        let content = root.view!

        let screenBounds = scene.screen.bounds
        let width = min(screenBounds.width * 0.85, 420)

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        dimView.alpha = 0
        dimView.accessibilityLabel = "Fermer"
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.addTarget(self, action: #selector(handleDimTap), for: .touchUpInside)
        content.addSubview(dimView)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(container)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.alpha = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        if let image {
            stack.addArrangedSubview(mediaCard(
                image: image,
                fileName: fileName,
                subtitle: subtitle,
                width: width,
                maxMediaHeight: screenBounds.height * 0.5
            ))
        }
        stack.addArrangedSubview(actionsCard(items: items))

        let centerY = stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        centerY.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: content.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.safeAreaLayoutGuide.bottomAnchor),

            container.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),

            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        centerY.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        windowLevel = .alert
        isHidden = false
        stack.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(
            withDuration: 0.38,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0,
            options: .allowUserInteraction
        ) {
            self.dimView.alpha = 1
            self.stack.alpha = 1
            self.stack.transform = .identity
        }
    }

    func dismiss(then action: (() -> Void)? = nil) {
        guard !didDismiss else { return }
        didDismiss = true
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.dimView.alpha = 0
            self.stack.alpha = 0
            self.stack.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        } completion: { _ in
            self.isHidden = true
            self.onDidDismiss()
            action?()
        }
    }

    @objc private func handleDimTap() {
        dismiss()
    }

    @objc private func handleMediaTap() {
        dismiss(then: onMediaTapped)
    }

    /// Carte média : image bord à bord en haut et sur les côtés, recadrée
    /// (`aspectFill`) — aucune bordure quelle que soit la résolution —,
    /// légende resserrée en bas avec la marge conservée.
    private func mediaCard(image: UIImage, fileName: String, subtitle: String?, width: CGFloat, maxMediaHeight: CGFloat) -> UIView {
        let card = UIView()
        card.backgroundColor = .black
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(imageView)

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
        card.addSubview(caption)

        let openButton = UIButton(type: .custom)
        openButton.accessibilityLabel = fileName
        openButton.accessibilityHint = "Ouvrir"
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.addTarget(self, action: #selector(handleMediaTap), for: .touchUpInside)
        card.addSubview(openButton)

        let ratio = image.size.height / max(image.size.width, 1)
        let mediaHeight: CGFloat
        if ratio.isFinite, ratio > 0 {
            mediaHeight = min(max(width * ratio, 160), maxMediaHeight)
        } else {
            mediaHeight = 240
        }

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: card.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            imageView.heightAnchor.constraint(equalToConstant: mediaHeight),
            caption.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            caption.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            openButton.topAnchor.constraint(equalTo: card.topAnchor),
            openButton.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            openButton.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            openButton.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Carte d'actions : lignes titre + icône SF, séparateurs fins,
    /// destructive en rouge — même contenu que l'ancien menu natif.
    private func actionsCard(items: [CardMenuItem]) -> UIView {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.layer.cornerRadius = 16
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        let list = UIStackView()
        list.axis = .vertical
        list.alignment = .fill
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -6),
        ])
        for (index, item) in items.enumerated() {
            let row = ActionRow(item: item) { [weak self] picked in
                guard let self else { return }
                self.dismiss(then: { self.onItemPicked(picked) })
            }
            if index < items.count - 1 {
                row.showsSeparator = true
            }
            list.addArrangedSubview(row)
        }
        return blur
    }

    /// Ligne d'action : icône + titre, fondu au toucher, séparateur
    /// optionnel — `UIControl` direct, sans API dépréciée.
    private final class ActionRow: UIControl {
        private let content = UIStackView()
        private let separator = UIView()
        var showsSeparator = false {
            didSet { separator.isHidden = !showsSeparator }
        }

        init(item: CardMenuItem, onTap: @escaping (CardMenuItem) -> Void) {
            super.init(frame: .zero)
            accessibilityLabel = item.title
            accessibilityTraits = .button

            let color: UIColor = item.destructive ? .systemRed : .label
            let icon = UIImageView(image: UIImage(systemName: item.systemImage))
            icon.tintColor = color
            icon.contentMode = .scaleAspectFit
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17)
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
            ])
            let label = UILabel()
            label.text = item.title
            label.font = .systemFont(ofSize: 16)
            label.textColor = color
            content.axis = .horizontal
            content.alignment = .center
            content.spacing = 12
            content.isUserInteractionEnabled = false
            content.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(icon)
            content.addArrangedSubview(label)
            addSubview(content)

            separator.backgroundColor = .separator
            separator.isHidden = true
            separator.isUserInteractionEnabled = false
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)

            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 46),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
                separator.heightAnchor.constraint(equalToConstant: 0.5),
                separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 50),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            addAction(UIAction { _ in onTap(item) }, for: .touchUpInside)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isHighlighted: Bool {
            didSet { content.alpha = isHighlighted ? 0.45 : 1 }
        }
    }
}

