import SwiftUI

/// Constantes de design partagées.
enum DS {
    /// Coins arrondis des cartes.
    static let cardRadius: CGFloat = 18
    /// Coins arrondis de la barre d'onglets flottante.
    static let tabBarRadius: CGFloat = 28
    /// Espacement horizontal entre cartes de la grille.
    static let gridSpacing: CGFloat = 10
    /// Marges latérales de la grille.
    static let gridMargin: CGFloat = 14
    /// Taille de miniature demandée à l'API (bucket arrondi, max 400).
    /// C'est aussi la clé canonique de tous les caches de miniatures : le
    /// serveur renvoie la même image quelle que soit la valeur demandée,
    /// une autre taille ne ferait que dupliquer téléchargements et caches.
    static let thumbnailPixels: Int = 360
    /// Hauteur réservée sous la barre de recherche flottante : le contenu de
    /// la grille est décalé de cette valeur quand la barre est visible.
    static let searchBarInset: CGFloat = 52
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
