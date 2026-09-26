import SwiftUI

@main
struct OrvianApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task {
                    await session.bootstrap()
                }
        }
    }
}
