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
    /// Noms des éléments de `tagsPath` pour le fil d'Ariane de l'onglet Tag :
    /// vit ici (et non dans `TagsView`) car la vue est démontée à chaque
    /// changement d'onglet, un `@State` local repartait donc de zéro et
    /// désynchronisait le breadcrumb au retour sur l'onglet.
    var tagsTrail: [String] = []
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
            tagsTrail = []
        case .profile:
            profilePath = NavigationPath()
            profileRefreshRequest += 1
        case .settings:
            settingsPath = NavigationPath()
        }
    }
}

/// État d'interface de l'écran d'onglets qui **survit au verrouillage**.
///
/// `RootView` démonte `MainTabView` dès qu'un code est configuré et que l'app
/// passe en arrière-plan : aucun contenu ne traîne derrière l'écran de
/// verrouillage, et aucune feuille/visionneuse ne peut rester présentée par-
/// dessus. Contrepartie : tout était reconstruit au déverrouillage et
/// l'utilisateur repartait de l'Accueil. Cet objet, possédé par la session
/// (donc hors de l'arbre démonté), conserve l'onglet courant, les piles de
/// navigation et le routeur de visionneuse pour les restituer au retour.
/// Les grilles, elles, se reconstituent depuis le cache mémoire des listes
/// (aucun squelette ni aller-retour si l'entrée est encore fraîche).
@MainActor
@Observable
final class MainTabShellState {
    let driveId: Int
    /// Onglet courant. `var` (et non `let`) pour permettre les bindings
    /// `$shell.tab` dans `MainTabView`.
    var tab: AppTab = .home
    /// Routeur des visionneuses plein écran. Recréé par drive ; `var` pour les
    /// bindings `$shell.router.mediaContext`.
    var router: ViewerRouter
    /// Piles de navigation des cinq onglets. `var` pour les mêmes raisons.
    var navState = TabNavigationState()

    init(driveId: Int) {
        self.driveId = driveId
        self.router = ViewerRouter(driveId: driveId)
    }
}
