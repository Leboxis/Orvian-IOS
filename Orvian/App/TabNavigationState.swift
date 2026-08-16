import SwiftUI
import Observation

/// État de navigation centralisé permettant le contrôle et la réinitialisation
/// à la racine lors d'un second appui sur le bouton de l'onglet actif.
@MainActor
@Observable
final class TabNavigationState {
    var homePath: [DriveFile] = []
    var favoritesPath: [DriveFile] = []
    var tagsPath = NavigationPath()
    var profilePath = NavigationPath()
    var settingsPath = NavigationPath()

    func reset(tab: AppTab) {
        withAnimation(.snappy(duration: 0.25)) {
            switch tab {
            case .home:
                homePath = []
            case .favorites:
                favoritesPath = []
            case .tag:
                tagsPath = NavigationPath()
            case .profile:
                profilePath = NavigationPath()
            case .settings:
                settingsPath = NavigationPath()
            }
        }
    }
}
