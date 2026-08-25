import SwiftUI

@main
struct OrvianApp: App {
    @State private var session = SessionStore()

    init() {
        // Le client API s'appuie sur la revalidation HTTP (ETag → 304) pour
        // accélérer les listes inchangées. Les capacités par défaut du
        // URLCache partagé étant modestes, elles sont relevées ici afin que
        // les réponses revalidables subsistent entre deux visites d'un dossier.
        let megabyte = 1_024 * 1_024
        URLCache.shared = URLCache(
            memoryCapacity: 20 * megabyte,
            diskCapacity: 150 * megabyte
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task {
                    await session.bootstrap()
                }
        }
    }
}
