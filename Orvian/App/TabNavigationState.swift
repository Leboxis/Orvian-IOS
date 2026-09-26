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
/// La session possède l'onglet, les piles et le routeur. Au verrouillage,
/// `AppPrivacyWindow` masque aussi les présentations plein écran sans détruire
/// cet état ni les vues montées. Le défilement et les états locaux restent
/// dans ces vues ; un changement de compte ou de drive remplace le shell.
@MainActor
@Observable
final class MainTabShellState {
    let driveId: Int
    /// Onglet courant. `var` (et non `let`) pour permettre les bindings
    /// `$shell.tab` dans `MainTabView`.
    var tab: AppTab = .home
    /// Onglets déjà visités. Un onglet conservé (`AppTab.isKeptAlive`) n'est
    /// monté qu'à partir de sa première visite : le gain du point 3 — pas de
    /// squelette, pas de perte de position au retour — sans charger trois
    /// grilles au lancement.
    private(set) var visitedTabs: Set<AppTab> = [.home]
    /// Routeur des visionneuses plein écran. Recréé par drive ; `var` pour les
    /// bindings `$shell.router.mediaContext`.
    var router: ViewerRouter
    /// Piles de navigation des cinq onglets. `var` pour les mêmes raisons.
    var navState = TabNavigationState()

    init(driveId: Int) {
        self.driveId = driveId
        self.router = ViewerRouter(driveId: driveId)
    }

    /// Marque un onglet comme visité, avant de le sélectionner pour que la vue
    /// puisse se monter dans le même tour.
    func markVisited(_ tab: AppTab) {
        visitedTabs.insert(tab)
    }
}
