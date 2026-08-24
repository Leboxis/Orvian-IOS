import SwiftUI
import UIKit

/// Espace de coordonnées partagé entre les cartes de la grille et la session
/// de glisser-déposer : toutes les positions (doigt, cadres) y sont exprimées.
let GridDragSpaceName = "fileGridDragSpace"

/// Géométrie d'une carte visible : cadre dans l'espace de la grille et
/// nature dossier/fichier (seuls les dossiers acceptent un dépôt).
struct CellGeometry: Equatable {
    let rect: CGRect
    let isDirectory: Bool
}

/// Réduit les géométries publiées par chaque carte en un dictionnaire unique.
struct CellFramesKey: PreferenceKey {
    static var defaultValue: [Int: CellGeometry] = [:]
    static func reduce(value: inout [Int: CellGeometry], nextValue: () -> [Int: CellGeometry]) {
        value.merge(nextValue(), uniquingKeysWith: { _, replacement in replacement })
    }
}

/// Publie le cadre d'une carte dans l'espace de la grille
/// (consommé par `.onPreferenceChange(CellFramesKey.self)`).
struct CellFrameReader: View {
    let file: DriveFile

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: CellFramesKey.self,
                value: [
                    file.id: CellGeometry(
                        rect: proxy.frame(in: .named(GridDragSpaceName)),
                        isDirectory: file.isDirectory
                    )
                ]
            )
        }
    }
}

/// État d'un glisser-déposer multi-éléments dans une grille de fichiers.
///
/// Cycle de vie : `begin` au soulèvement (appui long + mouvement), la carte
/// ancre suit le doigt pendant que les autres éléments soulevés se rassemblent
/// en gerbe autour d'elle ; au relâchement sur un dossier `beginDrop` fait
/// plonger la gerbe dedans, sinon `reset` renvoie chaque carte à sa place.
@MainActor
@Observable
final class GridDragSession {
    enum Phase: Equatable {
        case idle
        case lifting
        case dropping
    }

    /// Éléments soulevés, l'ancre en premier.
    private(set) var draggedIDs: [Int] = []
    /// Carte qui suit le doigt ; les autres se rassemblent autour d'elle.
    private(set) var anchorID: Int?
    /// Position courante du doigt dans l'espace de la grille.
    var location: CGPoint?
    private(set) var startLocation: CGPoint?
    /// Dossier actuellement survolé, candidat au dépôt.
    private(set) var hoveredFolderID: Int?
    /// Dossier cible après relâchement (phase `.dropping`).
    private(set) var dropTargetID: Int?
    /// Horodatage du dépôt : clé du minuteur de sécurité qui restaure les
    /// cartes si le déplacement réseau n'aboutit jamais.
    private(set) var dropStartedAt: Date?
    private(set) var phase: Phase = .idle

    var isActive: Bool { anchorID != nil }

    /// Déplacement du doigt depuis le point de soulèvement.
    var translation: CGSize {
        guard let startLocation, let location else { return .zero }
        return CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
    }

    func begin(ids: [Int], anchorID: Int, at point: CGPoint) {
        draggedIDs = ids
        self.anchorID = anchorID
        startLocation = point
        location = point
        hoveredFolderID = nil
        dropTargetID = nil
        dropStartedAt = nil
        phase = .lifting
    }

    /// Dossier sous le doigt, hors des éléments soulevés eux-mêmes.
    func updateHover(frames: [Int: CellGeometry]) {
        guard let location else { return }
        let lifted = Set(draggedIDs)
        hoveredFolderID = frames.first(where: { id, geometry in
            geometry.isDirectory && !lifted.contains(id) && geometry.rect.contains(location)
        })?.key
    }

    func beginDrop(into folderID: Int) {
        dropTargetID = folderID
        dropStartedAt = Date()
        phase = .dropping
    }

    /// Retour à l'état neutre ; à envelopper dans `withAnimation` pour voir
    /// les cartes revenir ou plonger avec un ressort.
    func reset() {
        draggedIDs = []
        anchorID = nil
        location = nil
        startLocation = nil
        hoveredFolderID = nil
        dropTargetID = nil
        dropStartedAt = nil
        phase = .idle
    }
}

// MARK: - Transformation des cartes soulevées

/// Apparence calculée d'une carte pendant la session.
private struct DragAppearance {
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    var opacity: Double = 1
    var shadowOpacity: Double = 0
    var shadowRadius: CGFloat = 0
    var shadowY: CGFloat = 0
    var zIndex: Double = 0
}

/// Déplace les cartes concernées par la session :
/// - l'ancre suit le doigt, agrandie et ombrée (effet « soulevée ») ;
/// - les autres éléments sélectionnés convergent en gerbe serrée autour
///   d'elle — c'est l'animation de rassemblement ;
/// - au dépôt, toute la gerbe rétrécit et disparaît dans le dossier cible ;
/// - à l'annulation, `session.reset()` ramène chaque carte chez elle.
struct DragCellTransform: ViewModifier {
    let session: GridDragSession
    let id: Int
    let geometry: CellGeometry?
    let frames: [Int: CellGeometry]

    func body(content: Content) -> some View {
        let appearance = transform
        return content
            .scaleEffect(appearance.scale)
            .offset(appearance.offset)
            .opacity(appearance.opacity)
            .shadow(
                color: .black.opacity(appearance.shadowOpacity),
                radius: appearance.shadowRadius,
                y: appearance.shadowY
            )
            .zIndex(appearance.zIndex)
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.phase)
    }

    private var transform: DragAppearance {
        guard session.isActive, let geometry else { return DragAppearance() }
        switch session.phase {
        case .idle:
            return DragAppearance()
        case .lifting:
            return liftedAppearance(of: geometry)
        case .dropping:
            return droppingAppearance ?? liftedAppearance(of: geometry)
        }
    }

    private var isAnchor: Bool { session.anchorID == id }

    private func liftedAppearance(of geometry: CellGeometry) -> DragAppearance {
        let delta = session.translation
        if isAnchor {
            return DragAppearance(
                offset: delta,
                scale: 1.06,
                opacity: 1,
                shadowOpacity: 0.30,
                shadowRadius: 18,
                shadowY: 9,
                zIndex: 100
            )
        }
        guard let index = session.draggedIDs.firstIndex(of: id),
              let anchorRect = frames[session.anchorID ?? -1]?.rect
        else { return DragAppearance() }

        // Gerbe : chaque carte vise un point juste derrière l'ancre, décalé
        // en éventail pour que l'ensemble ressemble à une pile tenue ensemble.
        let followerCount = max(session.draggedIDs.count - 1, 1)
        let slot = index - 1
        let angle = Double(slot) / Double(followerCount) * .pi * 1.5 - .pi * 0.75
        let radius: CGFloat = followerCount <= 1 ? 0 : 15
        let cluster = CGSize(
            width: cos(angle) * radius,
            height: sin(angle) * radius * 0.75
        )
        let target = CGPoint(
            x: anchorRect.midX + delta.width + cluster.width,
            y: anchorRect.midY + delta.height + cluster.height
        )
        return DragAppearance(
            offset: CGSize(
                width: target.x - geometry.rect.midX,
                height: target.y - geometry.rect.midY
            ),
            scale: 0.55,
            opacity: 0.92,
            shadowOpacity: 0.20,
            shadowRadius: 12,
            shadowY: 6,
            zIndex: 60 - Double(index)
        )
    }

    /// Phase finale : toute la gerbe plonge vers le centre du dossier cible.
    private var droppingAppearance: DragAppearance? {
        guard let folderRect = frames[session.dropTargetID ?? -1]?.rect,
              let anchorRect = frames[session.anchorID ?? -1]?.rect
        else { return nil }

        if isAnchor {
            return DragAppearance(
                offset: CGSize(
                    width: folderRect.midX - anchorRect.midX,
                    height: folderRect.midY - anchorRect.midY
                ),
                scale: 0.12,
                opacity: 0,
                zIndex: 100
            )
        }

        // Les suiveurs convergent eux aussi vers le dossier, avec un léger
        // décalage pour garder l'effet de pile pendant la chute.
        guard let index = session.draggedIDs.firstIndex(of: id),
              let geometry
        else { return nil }
        let followerCount = max(session.draggedIDs.count - 1, 1)
        let slot = index - 1
        let angle = Double(slot) / Double(followerCount) * .pi * 1.5 - .pi * 0.75
        let jitterRadius: CGFloat = followerCount <= 1 ? 0 : 6
        let target = CGPoint(
            x: folderRect.midX + cos(angle) * jitterRadius,
            y: folderRect.midY + sin(angle) * jitterRadius
        )
        return DragAppearance(
            offset: CGSize(
                width: target.x - geometry.rect.midX,
                height: target.y - geometry.rect.midY
            ),
            scale: 0.10,
            opacity: 0,
            zIndex: 90 - Double(index)
        )
    }
}

// MARK: - Verrou du défilement pendant le transport

/// Verrouille directement `isScrollEnabled` du `UIScrollView` englobant.
///
/// Passer par `.scrollDisabled()` ne marche pas ici : basculer le modificateur
/// en plein geste invalide la configuration de gestes du ScrollView, ce qui
/// annule le recognizeur actif (et peut laisser la session de glisser sans
/// événement final — scroll mort). Toucher la propriété UIKit ne dérange pas
/// le geste SwiftUI simultané déjà en cours.
@MainActor
final class ScrollLocker {
    private weak var scrollView: UIScrollView?

    /// Résout le scrollView ancêtre une fois, depuis un repose dans le contenu.
    func resolve(from view: UIView) {
        guard scrollView == nil else { return }
        var current: UIView? = view
        while let node = current {
            if let scrollView = node as? UIScrollView {
                self.scrollView = scrollView
                return
            }
            current = node.superview
        }
    }

    func setLocked(_ locked: Bool) {
        guard let scrollView else { return }
        if locked {
            // Un rafraîchissement amorcé au doigt doit s'arrêter avec le scroll.
            scrollView.refreshControl?.endRefreshing()
        }
        scrollView.isScrollEnabled = !locked
    }
}

/// Repose invisible placé dans le contenu du ScrollView : sert uniquement de
/// point d'entrée pour retrouver l'ancêtre `UIScrollView`.
struct ScrollLockerMarker: View {
    let locker: ScrollLocker

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background(Resolver(locker: locker))
    }

    private struct Resolver: UIViewRepresentable {
        let locker: ScrollLocker

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                locker.resolve(from: view)
            }
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}

// MARK: - Mise en avant du dossier survolé

/// Cerne et teinte légèrement le dossier sous le doigt pendant la session,
/// pour annoncer la destination du dépôt.
struct FolderDropHighlight: ViewModifier {
    let isTargeted: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(isTargeted ? 0.14 : 0))
                        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.9 : 0), lineWidth: 3)
                    }
                    .allowsHitTesting(false)
            }
            .scaleEffect(isTargeted ? 1.05 : 1)
            .animation(.snappy(duration: 0.22), value: isTargeted)
    }
}
