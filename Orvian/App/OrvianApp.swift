import SwiftUI

@main
struct OrvianApp: App {
    init() { BrowserPreferences.migrate() }
    @State private var session = SessionStore()
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                // SF Pro hérité par tous les écrans, y compris les présentations.
                .font(.body)
                .fontDesign(.default)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    await session.bootstrap()
                }
        }
    }
}
