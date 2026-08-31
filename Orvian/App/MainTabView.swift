import SwiftUI

/// Conteneur des 5 onglets + barre flottante + visionneuses plein écran + suivi d'upload.
///
/// Barre, de gauche à droite : Réglages · Tag · Accueil · Favoris · Profil.
/// Seul l'onglet Accueil reste monté en permanence : ses données et sa
/// position de scroll survivent aux changements d'onglet. Les autres onglets
/// sont recréés à chaque visite (leur pile de navigation vit dans
/// `TabNavigationState`), ce qui limite la mémoire consommée.
struct MainTabView: View {
    let drive: Drive
    let session: SessionStore

    @State private var tab: AppTab = .home
    @State private var router: ViewerRouter
    @State private var navState = TabNavigationState()
    @State private var showUploadSheet = false
    @StateObject private var downloadService = FileDownloadService.shared
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true

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
                if downloadService.isDownloading {
                    DownloadProgressBanner(service: downloadService) {
                        downloadService.cancelDownload()
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }

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
            .animation(.snappy(duration: 0.28), value: downloadService.isDownloading)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(.accentColor)
        .sheet(isPresented: $showUploadSheet) {
            UploadProgressSheet(manager: uploadManager)
        }
        .fullScreenCover(item: $router.mediaContext) { context in
            MediaPagerView(context: context)
        }
        .fullScreenCover(item: $router.textFile) { file in
            TextFileViewer(file: file, driveId: drive.id)
        }
        .alert("Téléchargement impossible", isPresented: downloadErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadService.errorMessage ?? "")
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
                HomeTab(
                    driveId: drive.id,
                    router: router,
                    isSelected: tab == .home,
                    path: $navState.homePath
                )
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
        // Seul l'Accueil reste monté en permanence (état de scroll et données
        // conservés) ; les autres onglets ne sont montés que lorsqu'ils sont
        // sélectionnés, ce qui libère leurs vues à chaque changement d'onglet.
        if target == .home || target == tab {
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

    private var downloadErrorBinding: Binding<Bool> {
        Binding(
            get: { downloadService.errorMessage != nil },
            set: { if !$0 { downloadService.errorMessage = nil } }
        )
    }
}

/// Bannière compacte au-dessus de la barre d'onglets : progression réelle du
/// téléchargement en cours et bouton d'annulation. L'ancien comportement ne
/// fournissait aucun retour ni moyen d'arrêter un transfert, parfois long.
private struct DownloadProgressBanner: View {
    @ObservedObject var service: FileDownloadService
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if service.progress > 0.001 {
                ProgressView(value: service.progress)
                    .tint(Color.accentColor)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(service.downloadingFileName ?? "Téléchargement…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if service.progress > 0.001 {
                    Text("\(Int((service.progress * 100).rounded())) %")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button("Annuler", action: onCancel)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 5)
        .padding(.horizontal, DS.gridMargin + 8)
        .accessibilityLabel("Téléchargement en cours")
    }
}
