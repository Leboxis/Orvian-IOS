import SwiftUI

@main
struct OrvianApp: App {
    @State private var session = SessionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                // SF Pro hérité par tous les écrans, y compris les présentations.
                .font(.body)
                .fontDesign(.default)
                .task {
                    await session.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { FolderImageScanner.shared.cancel() }
                }
        }
    }
}
