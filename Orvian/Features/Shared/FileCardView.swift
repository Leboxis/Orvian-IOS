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
                        } else if showsFavoriteBadge && showFavoriteStars {
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
        // Aperçu détaché au long-press (pattern Fichiers.app) : uniquement
        // pour les médias, et uniquement quand la miniature est déjà en cache.
        // L'aperçu flotte au-dessus du contenu, le menu complet est conservé.
        .overlay {
            if hasQuickPreview, thumbnail != nil, !selectionMode, enabled {
                QuickLookInteraction(
                    previewImage: thumbnail!,
                    fileName: file.name,
                    onCommit: { action() }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(true)
            }
        }
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

/// Interaction UIKit qui détecte le long-press sur la carte et présente
/// l'aperçu détaché grand format (pattern Fichiers.app). L'aperçu flotte
/// au-dessus du contenu avec un fond flouté ; le menu contextuel SwiftUI
/// existant reste disponible au relâchement.
private struct QuickLookInteraction: UIViewRepresentable {
    let previewImage: UIImage
    let fileName: String
    /// Action d'ouverture complète, appelée quand l'utilisateur relève le
    /// doigt sur l'aperçu (tap-to-open).
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(previewImage: previewImage, fileName: fileName, onCommit: onCommit)
    }

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        context.coordinator.previewImage = previewImage
        context.coordinator.fileName = fileName
    }

    /// Vue transparente qui capte le long-press sans interférer avec les
    /// taps normaux (le bouton SwiftUI en dessous reçoit les taps courts).
    final class InteractionView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            gesture.minimumPressDuration = 0.45
            gesture.allowableMovement = 8
            addGestureRecognizer(gesture)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let coordinator else { return }
            coordinator.presentPreview(from: self)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var previewImage: UIImage
        var fileName: String
        let onCommit: () -> Void

        private var overlayWindow: UIWindow?

        init(previewImage: UIImage, fileName: String, onCommit: @escaping () -> Void) {
            self.previewImage = previewImage
            self.fileName = fileName
            self.onCommit = onCommit
        }

        func presentPreview(from sourceView: UIView) {
            guard let windowScene = sourceView.window?.windowScene else { return }
            let window = UIWindow(windowScene: windowScene)

            let controller = QuickLookPreviewViewController(
                image: previewImage,
                fileName: fileName,
                sourceFrame: sourceView.convert(sourceView.bounds, to: nil),
                onCommit: { [weak self] in
                    self?.dismissPreview()
                    self?.onCommit()
                },
                onDismiss: { [weak self] in
                    self?.dismissPreview()
                }
            )

            window.windowLevel = .alert + 1
            window.rootViewController = controller
            window.makeKeyAndVisible()
            overlayWindow = window
        }

        func dismissPreview() {
            guard let window = overlayWindow else { return }
            UIView.animate(withDuration: 0.2, animations: {
                window.alpha = 0
            }, completion: { _ in
                window.isHidden = true
                window.rootViewController = nil
                self.overlayWindow = nil
            })
        }
    }
}

/// Contrôleur plein écran de l'aperçu rapide : fond flouté, image agrandie
/// animée depuis la position de la carte, nom du fichier en légende.
/// Tap sur l'image → ouverture complète. Tap sur le fond → fermeture.
private final class QuickLookPreviewViewController: UIViewController {
    private let image: UIImage
    private let fileName: String
    private let sourceFrame: CGRect
    private let onCommit: () -> Void
    private let onDismiss: () -> Void

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let imageView = UIImageView()
    private let nameLabel = UILabel()
    private let containerView = UIView()

    init(
        image: UIImage,
        fileName: String,
        sourceFrame: CGRect,
        onCommit: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.image = image
        self.fileName = fileName
        self.sourceFrame = sourceFrame
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        blurView.alpha = 0
        blurView.frame = view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blurView)

        // Taille cible : bornée à 85 % de la largeur, 72 % de la hauteur.
        let maxSize = CGSize(
            width: view.bounds.width * 0.85,
            height: view.bounds.height * 0.72
        )
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 1
        var targetSize = CGSize(width: maxSize.width, height: maxSize.width * aspect)
        if targetSize.height > maxSize.height {
            targetSize = CGSize(width: maxSize.height / max(aspect, 0.01), height: maxSize.height)
        }

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        imageView.isUserInteractionEnabled = true

        nameLabel.text = fileName
        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle

        containerView.addSubview(imageView)
        containerView.addSubview(nameLabel)
        view.addSubview(containerView)

        imageView.frame = CGRect(origin: .zero, size: targetSize)
        nameLabel.frame = CGRect(
            x: 0, y: targetSize.height + 12,
            width: targetSize.width, height: 20
        )
        containerView.frame = CGRect(
            x: (view.bounds.width - targetSize.width) / 2,
            y: (view.bounds.height - targetSize.height - 32) / 2,
            width: targetSize.width,
            height: targetSize.height + 32
        )

        // Animation d'ouverture : l'aperçu part de la position de la carte.
        containerView.frame = CGRect(
            x: sourceFrame.midX - targetSize.width / 2,
            y: sourceFrame.midY - (targetSize.height + 32) / 2,
            width: targetSize.width,
            height: targetSize.height + 32
        )
        let scaleX = max(sourceFrame.width / max(targetSize.width, 1), 0.05)
        let scaleY = max(sourceFrame.height / max(targetSize.height + 32, 1), 0.05)
        containerView.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        containerView.alpha = 0

        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) {
            self.blurView.alpha = 1
            self.containerView.transform = .identity
            self.containerView.frame = CGRect(
                x: (self.view.bounds.width - targetSize.width) / 2,
                y: (self.view.bounds.height - targetSize.height - 32) / 2,
                width: targetSize.width,
                height: targetSize.height + 32
            )
            self.containerView.alpha = 1
        }

        let tapImage = UITapGestureRecognizer(target: self, action: #selector(handleTapImage))
        imageView.addGestureRecognizer(tapImage)

        let tapBackground = UITapGestureRecognizer(target: self, action: #selector(handleTapBackground))
        blurView.addGestureRecognizer(tapBackground)
    }

    @objc private func handleTapImage() {
        onCommit()
    }

    @objc private func handleTapBackground() {
        onDismiss()
    }
}

