import SwiftUI
import Observation

/// État de navigation centralisé permettant le contrôle et la réinitialisation
/// à la racine lors d'un second appui sur le bouton de l'onglet actif.
@MainActor
@Observable
final class TabNavigationState {
    var homePath: [DriveFile] = []
    var favoritesPath: [DriveFile] = []
    /// Incrémente à chaque nouvel appui sur Favoris afin de demander à la
    /// grille racine de revenir au tout début, même sans navigation ouverte.
    var favoritesScrollToTopRequest = 0
    var tagsPath = NavigationPath()
    var profilePath = NavigationPath()
    /// Incrémente à chaque second appui sur l'onglet Profil afin de demander
    /// un retour à la racine ET un rafraîchissement des sections.
    var profileRefreshRequest = 0
    var settingsPath = NavigationPath()

    func reset(tab: AppTab, scrollFavoritesToTop: Bool = true) {
        switch tab {
        case .home:
            homePath = []
        case .favorites:
            favoritesPath = []
            if scrollFavoritesToTop {
                favoritesScrollToTopRequest += 1
            }
        case .tag:
            tagsPath = NavigationPath()
        case .profile:
            profilePath = NavigationPath()
            profileRefreshRequest += 1
        case .settings:
            settingsPath = NavigationPath()
        }
    }
}
