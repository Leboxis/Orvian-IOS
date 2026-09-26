import SwiftUI

/// Constantes de design partagées.
///
/// Le chrome flottant (barre d'onglets, pastilles de transfert, bouton
/// d'import, champ de recherche) répétait la même recette dans chaque vue,
/// avec des ombres allant de 0,04 à 0,15 d'opacité et sept rayons de coins
/// différents pour des surfaces comparables : les pastilles posées côte à
/// côte ne se ressemblaient donc pas. Les jetons ci-dessous sont la source
/// unique de ces valeurs ; les modificateurs `floatingChrome` /
/// `inlineChrome` / `inputChrome` en portent l'application.
enum DS {
    // MARK: - Rayons

    /// Coins arrondis des cartes de fichiers.
    static let cardRadius: CGFloat = 18
    /// Coins arrondis de la barre d'onglets flottante.
    static let tabBarRadius: CGFloat = 28
    /// Coins arrondis des panneaux pleine largeur (cartes de Réglages).
    static let panelRadius: CGFloat = 22
    /// Coins arrondis des surfaces compactes (vignettes, lignes, liserés).
    static let compactRadius: CGFloat = 12
    /// Coins arrondis des plus petits éléments (icônes de tags, barres fines).
    static let smallRadius: CGFloat = 8

    // MARK: - Espacements

    /// Espacement horizontal entre cartes des grilles.
    static let gridSpacing: CGFloat = 10
    /// Marges latérales des grilles.
    static let gridMargin: CGFloat = 14

    // MARK: - Largeurs maximales (iPad)

    /// Largeur maximale du contenu d'une grille : au-delà, les colonnes
    /// s'étirent et la lecture se perd sur iPad. Le bloc reste centré, sans
    /// toucher au nombre de colonnes choisi par l'utilisateur.
    static let maxContentWidth: CGFloat = 900
    /// Largeur maximale de la barre d'onglets flottante : sans cette borne,
    /// ses cinq onglets occupent toute la largeur d'un iPad.
    static let maxTabBarWidth: CGFloat = 560

    // MARK: - Marges basses du contenu

    /// Espace réservé sous une grille pour la barre d'onglets flottante **et**
    /// pour la pastille de transfert qui flotte au-dessus d'elle. Égal à
    /// `floatingPillInset` : sans cela, une pastille visible recouvrirait le
    /// bas de la dernière rangée de cartes.
    static let floatingBarInset: CGFloat = 130
    /// Marge basse des actions superposées à la barre (bouton « + »).
    static let floatingActionInset: CGFloat = 104
    /// Marge basse des pastilles de progression centrées au-dessus de la barre.
    static let floatingPillInset: CGFloat = 130

    // MARK: - Ombres

    /// Ombre du chrome flottant (barre d'onglets, pastilles, bouton « + »).
    static let floatingShadow = Color.black.opacity(0.12)
    static let floatingShadowRadius: CGFloat = 12
    static let floatingShadowY: CGFloat = 5
    /// Ombre très légère des pastilles d'information en ligne (fil d'Ariane,
    /// compteur d'éléments) : elles bordent le contenu sans flotter dessus.
    static let inlineShadow = Color.black.opacity(0.04)
    static let inlineShadowRadius: CGFloat = 2
    static let inlineShadowY: CGFloat = 1
    /// Ombre du champ de recherche : entre les deux, pour qu'il se détache
    /// de la grille sans rivaliser avec la barre d'onglets.
    static let inputShadow = Color.black.opacity(0.08)
    static let inputShadowRadius: CGFloat = 6
    static let inputShadowY: CGFloat = 2
}

/// Fond translucide, liseré et ombre appliqués d'un coup, avec la même
/// matière et le même liseré (0,5 pt) pour tout le chrome flottant.
private struct ChromeBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let material: Material
    let shadow: Color
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background(material, in: shape)
            .overlay {
                shape.strokeBorder(HierarchicalShapeStyle.quaternary, lineWidth: 0.5)
            }
            .shadow(color: shadow, radius: shadowRadius, x: 0, y: shadowY)
    }
}

extension View {
    /// Chrome flottant : matière translucide, liseré et ombre marquée.
    func floatingChrome<S: InsettableShape>(_ shape: S) -> some View {
        modifier(ChromeBackground(
            shape: shape,
            material: .ultraThinMaterial,
            shadow: DS.floatingShadow,
            shadowRadius: DS.floatingShadowRadius,
            shadowY: DS.floatingShadowY
        ))
    }

    /// Pastille d'information discrète : même matière et même liseré, ombre
    /// réduite au minimum pour ne pas concurrencer le chrome flottant.
    func inlineChrome<S: InsettableShape>(_ shape: S) -> some View {
        modifier(ChromeBackground(
            shape: shape,
            material: .ultraThinMaterial,
            shadow: DS.inlineShadow,
            shadowRadius: DS.inlineShadowRadius,
            shadowY: DS.inlineShadowY
        ))
    }

    /// Champ de saisie : matière `.bar`, plus opaque, pour que le texte reste
    /// lisible par-dessus un contenu qui défile.
    func inputChrome<S: InsettableShape>(_ shape: S) -> some View {
        modifier(ChromeBackground(
            shape: shape,
            material: .bar,
            shadow: DS.inputShadow,
            shadowRadius: DS.inputShadowRadius,
            shadowY: DS.inputShadowY
        ))
    }
}

/// Titre de section discrêt au-dessus des groupes de fichiers.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Vue d'état vide réutilisable.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .padding(.top, 60)
    }
}
