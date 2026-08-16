import SwiftUI

/// Conteneur des 5 onglets + barre flottante + visionneuses plein écran.
///
/// Les onglets restent montés (ZStack + opacité) pour conserver la
/// navigation et la position de scroll quand on change d'onglet.
struct MainTabView: View {
    let drive: Drive
    let session: SessionStore

    @State private var tab: AppTab = .recents
    @State private var router: ViewerRouter

    init(drive: Drive, session: SessionStore) {
        self.drive = drive
        self.session = session
        _router = State(initialValue: ViewerRouter(driveId: drive.id))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            tabs
            FloatingTabBar(selection: $tab)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(.accentColor)
        .fullScreenCover(item: $router.photoContext) { context in
            PhotoViewerView(context: context)
        }
        .fullScreenCover(item: $router.videoFile) { file in
            VideoPlayerView(file: file, driveId: drive.id)
        }
    }

    @ViewBuilder
    private var tabs: some View {
        ZStack {
            tabPane(.recents) {
                RecentsView(driveId: drive.id, router: router)
            }
            tabPane(.files) {
                FilesTab(driveId: drive.id, driveName: drive.name, router: router)
            }
            tabPane(.favorites) {
                FavoritesView(driveId: drive.id, router: router)
            }
            tabPane(.media) {
                MediaLibraryView(driveId: drive.id, router: router)
            }
            tabPane(.more) {
                MoreView(session: session)
            }
        }
    }

    private func tabPane(_ target: AppTab, @ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(tab == target ? 1 : 0)
            .allowsHitTesting(tab == target)
            .accessibilityHidden(tab != target)
    }
}
