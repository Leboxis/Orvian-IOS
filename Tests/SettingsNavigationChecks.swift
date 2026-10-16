import Foundation

// Seules les dépendances SwiftUI sont remplacées ; TabNavigationState reste celui de l’app.
struct DriveFile {}
struct NavigationPath { init() {} }
enum AppTab { case home, favorites, tag, profile, settings }

@main
enum SettingsNavigationChecks {
    @MainActor
    static func main() {
        let navigation = TabNavigationState()
        navigation.settingsPath = [.security]
        assert(navigation.settingsPath.last == .security)
        navigation.reset(tab: .home)
        assert(navigation.settingsPath.last == .security)
        navigation.settingsPath = [.account]
        assert(navigation.settingsPath.last == .account)
        navigation.reset(tab: .settings)
        assert(navigation.settingsPath.isEmpty)
        print("Settings navigation checks passed")
    }
}
