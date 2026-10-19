import SwiftUI

extension EnvironmentValues {
    @Entry var phoneBottomChromeHeight: CGFloat = 0
}

/// Conteneur des 5 onglets + barre flottante + visionneuses plein écran + suivi d'upload.
///
/// Barre, de gauche à droite : Réglages · Tag · Accueil · Favoris · Profil.
/// Accueil, Favoris et Tag restent montés d'une visite à l'autre : leurs
/// données et leur position de scroll survivent aux changements d'onglet.
/// Réglages et Profil sont recréés à chaque visite (leur pile de navigation
/// vit dans `TabNavigationState`), ce qui limite la mémoire consommée.
///
/// Le verrouillage couvre cet arbre sans le démonter. Les présentations,
/// positions de défilement et piles survivent au passage en arrière-plan.
/// Sur iPad, les onglets natifs remplacent la rétention manuelle décrite ci-dessus pour l'iPhone.
struct MainTabView: View {
    let drive: Drive
    let session: SessionStore

    /// Navigation possédée par la session, remplacée au changement de drive.
    let shell: MainTabShellState
    @State private var showUploadSheet = false
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true
    @AppStorage("iPadTabBarAtBottom") private var iPadTabBarAtBottom = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var iPadWidth: CGFloat = 0
    @State private var phoneBottomChromeHeight: CGFloat = 0

    private let uploadManager = UploadManager.shared

    init(drive: Drive, session: SessionStore, shell: MainTabShellState) {
        self.drive = drive
        self.session = session
        self.shell = shell
    }

    var body: some View {
        // Pattern @Observable : donne accès aux bindings `$shell.tab`,
        // `$shell.router.mediaContext`, `$shell.navState.homePath`…
        @Bindable var shell = shell
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                if iPadTabBarAtBottom {
                    phoneNavigation
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { iPadWidth = $0 }
                        .environment(\.iPadLayout, IPadLayout(isPad: true, width: iPadWidth,
                                                            largeText: dynamicTypeSize.isAccessibilitySize))
                } else {
                    IPadTabView(selection: iPadSelection) { tab in
                        tabContent(tab)
                            .environment(\.isActiveTab, shell.tab == tab)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TransferOverlayChrome(
                            uploadManager: uploadManager,
                            onShowUploads: { showUploadSheet = true }
                        )
                        .frame(maxWidth: DS.maxTabBarWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                    }
                }
            } else {
                phoneNavigation
            }
        }
        .tint(.accentColor)
        .sheet(isPresented: $showUploadSheet) {
            UploadProgressSheet(manager: uploadManager)
        }
        .fullScreenCover(item: $shell.router.mediaContext) { context in
            MediaPagerView(context: context)
                .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $shell.router.textFile) { file in
            TextFileViewer(file: file, driveId: drive.id)
        }
    }

    @ViewBuilder
    private var phoneNavigation: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Preserve the optional iPad bottom-bar layout.
            tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                bottomNavigationChrome
            }
        } else {
            // Keep the scroll viewport behind the glass; reserve reachability in content instead.
            tabs
                .background {
                    Color(uiColor: .systemGroupedBackground)
                        .ignoresSafeArea(edges: .bottom)
                }
                .environment(\.phoneBottomChromeHeight, phoneBottomChromeHeight)
                .overlay(alignment: .bottom) {
                    bottomNavigationChrome
                        .padding(.top, 8)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            phoneBottomChromeHeight = $0
                        }
                }
        }
    }

    private var bottomNavigationChrome: some View {
        @Bindable var shell = shell
        return VStack(spacing: 0) {
            TransferOverlayChrome(
                uploadManager: uploadManager,
                onShowUploads: { showUploadSheet = true }
            )

            FloatingTabBar(
                selection: $shell.tab,
                onSelect: prepareTab,
                onReselect: { targetTab in
                    shell.navState.reset(
                        tab: targetTab,
                        scrollFavoritesToTop: favoritesReselectScrollToTop
                    )
                }
            )
        }
        .padding(.bottom, 4)
    }

    private var iPadSelection: Binding<AppTab> {
        Binding(
            get: { shell.tab },
            set: { targetTab in
                guard targetTab != shell.tab else { return }
                prepareTab(targetTab)
                shell.tab = targetTab
            }
        )
    }

    private func prepareTab(_ targetTab: AppTab) {
        // Avant la sélection : l'onglet doit pouvoir se monter
        // dans le même tour pour ne pas afficher un cadre vide.
        shell.markVisited(targetTab)
        guard targetTab == .profile else { return }
        // Démarre au clic, avant que ProfileView soit montée.
        // Sa propre tâche rejoint ensuite la même requête.
        RecentUploadsLoader.shared.prefetch(driveId: drive.id)
    }

    private var tabs: some View {
        ZStack {
            tabPane(.settings) { tabContent(.settings) }
            tabPane(.tag) { tabContent(.tag) }
            tabPane(.home) { tabContent(.home) }
            tabPane(.favorites) { tabContent(.favorites) }
            tabPane(.profile) { tabContent(.profile) }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        // Même pattern que `body` : bindings vers l'état persistant.
        @Bindable var shell = shell
        switch tab {
        case .settings:
            SettingsView(session: session, path: $shell.navState.settingsPath,
                         selectedSpace: $shell.navState.settingsSelection,
                         columnVisibility: $shell.navState.splitVisibility)
        case .tag:
            TagsView(
                driveId: drive.id,
                router: shell.router,
                path: $shell.navState.tagsPath,
                trail: $shell.navState.tagsTrail,
                padNavigation: $shell.navState.iPadTags,
                columnVisibility: $shell.navState.splitVisibility,
                crossState: $shell.navState.tagIntersection
            )
            .environment(\.fileBrowserScope, .tag)
        case .home:
            HomeTab(
                driveId: drive.id,
                router: shell.router,
                isSelected: shell.tab == .home,
                path: $shell.navState.homePath
            )
        case .favorites:
            FavoritesView(
                driveId: drive.id,
                router: shell.router,
                path: $shell.navState.favoritesPath,
                scrollToTopRequest: shell.navState.favoritesScrollToTopRequest
            )
            .environment(\.fileBrowserScope, .favorites)
        case .profile:
            ProfileView(
                session: session,
                router: shell.router,
                path: $shell.navState.profilePath,
                isSelected: shell.tab == .profile,
                refreshRequest: shell.navState.profileRefreshRequest
            )
        }
    }

    private func phonePaneReservesChrome(_ tab: AppTab) -> Bool {
        UIDevice.current.userInterfaceIdiom != .pad && (tab == .settings || tab == .profile)
    }

    @ViewBuilder
    private func tabPane(_ target: AppTab, @ViewBuilder content: () -> some View) -> some View {
        // Accueil, Favoris et Tag restent montés une fois visités (données et
        // position de défilement conservées) ; Réglages et Profil ne sont
        // montés que lorsqu'ils sont sélectionnés, ce qui libère leurs vues à
        // chaque changement d'onglet. `isSelected` évite le montage anticipé
        // d'un onglet conservé jamais ouvert.
        if target == shell.tab || (target.isKeptAlive && shell.visitedTabs.contains(target)) {
            content()
                .safeAreaPadding(.bottom, phonePaneReservesChrome(target) ? phoneBottomChromeHeight : 0)
                .environment(\.phoneBottomChromeHeight, phonePaneReservesChrome(target) ? 0 : phoneBottomChromeHeight)
                .environment(\.isActiveTab, shell.tab == target)
                .opacity(shell.tab == target ? 1 : 0)
                .allowsHitTesting(shell.tab == target)
                .accessibilityHidden(shell.tab != target)
        } else {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Isole les mises à jour fréquentes de progression de la racine qui héberge
/// les onglets. Un tick de transfert ne reconstruit ainsi que ces deux pastilles.
private struct TransferOverlayChrome: View {
    let uploadManager: UploadManager
    let onShowUploads: () -> Void

    @StateObject private var downloadService = FileDownloadService.shared

    var body: some View {
        VStack(spacing: 0) {
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
                    onShowUploads()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.9))
                ))
            }

            if downloadService.isDownloading || uploadManager.isPillVisible {
                Color.clear.frame(height: 8)
            }
        }
        .animation(Motion.animation(.snappy(duration: 0.28)), value: uploadManager.isPillVisible)
        .animation(Motion.animation(.snappy(duration: 0.28)), value: downloadService.isDownloading)
        .alert("Téléchargement impossible", isPresented: downloadErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadService.errorMessage ?? "")
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

            Button(action: onCancel) {
                Text("Annuler")
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingChrome(Capsule())
        .padding(.horizontal, DS.gridMargin + 8)
        .accessibilityLabel("Téléchargement en cours")
    }
}
