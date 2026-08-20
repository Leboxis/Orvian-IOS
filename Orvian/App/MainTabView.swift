import SwiftUI

/// Conteneur des 5 onglets + barre flottante + visionneuses plein écran + suivi d'upload.
///
/// Barre, de gauche à droite : Réglages · Tag · Accueil · Favoris · Profil.
/// Les onglets restent montés (ZStack + opacité) pour conserver la
/// navigation et la position de scroll quand on change d'onglet.
struct MainTabView: View {
    let drive: Drive
    let session: SessionStore

    @State private var tab: AppTab = .home
    @State private var loadedTabs: Set<AppTab> = [.home]
    @State private var router: ViewerRouter
    @State private var navState = TabNavigationState()
    @State private var showUploadSheet = false
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true
    @AppStorage("reduceMotion") private var reduceMotion = false

    private let uploadManager = UploadManager.shared

    init(drive: Drive, session: SessionStore) {
        self.drive = drive
        self.session = session
        _router = State(initialValue: ViewerRouter(driveId: drive.id))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            tabs

            VStack(spacing: 8) {
                if uploadManager.isPillVisible {
                    UploadProgressPill(manager: uploadManager) {
                        showUploadSheet = true
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }

                FloatingTabBar(selection: $tab, onReselect: { targetTab in
                    navState.reset(
                        tab: targetTab,
                        scrollFavoritesToTop: favoritesReselectScrollToTop
                    )
                })
            }
            .padding(.bottom, 4)
            .animation(.snappy(duration: 0.28), value: uploadManager.isPillVisible)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(.accentColor)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
        .onChange(of: tab, initial: true) { _, newTab in
            if !loadedTabs.contains(newTab) {
                loadedTabs.insert(newTab)
            }
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadProgressSheet(manager: uploadManager)
        }
        .fullScreenCover(item: $router.photoContext) { context in
            PhotoViewerView(context: context)
        }
        .fullScreenCover(item: $router.videoFile) { file in
            VideoPlayerView(file: file, driveId: drive.id)
        }
        .fullScreenCover(item: $router.textFile) { file in
            TextFileViewer(file: file, driveId: drive.id)
        }
    }

    @ViewBuilder
    private var tabs: some View {
        ZStack {
            tabPane(.settings) {
                SettingsView(session: session, path: $navState.settingsPath)
            }
            tabPane(.tag) {
                TagsView(driveId: drive.id, router: router, path: $navState.tagsPath)
            }
            tabPane(.home) {
                HomeTab(driveId: drive.id, router: router, path: $navState.homePath)
            }
            tabPane(.favorites) {
                FavoritesView(
                    driveId: drive.id,
                    router: router,
                    path: $navState.favoritesPath,
                    scrollToTopRequest: navState.favoritesScrollToTopRequest
                )
            }
            tabPane(.profile) {
                ProfileView(
                    session: session,
                    router: router,
                    path: $navState.profilePath,
                    isSelected: tab == .profile,
                    refreshRequest: navState.profileRefreshRequest
                )
            }
        }
    }

    @ViewBuilder
    private func tabPane(_ target: AppTab, @ViewBuilder content: () -> some View) -> some View {
        if loadedTabs.contains(target) {
            content()
                .opacity(tab == target ? 1 : 0)
                .allowsHitTesting(tab == target)
                .accessibilityHidden(tab != target)
        } else {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
