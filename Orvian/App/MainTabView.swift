import SwiftUI

/// Conteneur des 5 onglets + barre flottante + visionneuses plein écran + suivi d'upload.
///
/// Barre, de gauche à droite : Réglages · Tag · Accueil · Favoris · Profil.
/// Seul l'onglet Accueil reste monté en permanence : ses données et sa
/// position de scroll survivent aux changements d'onglet. Les autres onglets
/// sont recréés à chaque visite (leur pile de navigation vit dans
/// `TabNavigationState`), ce qui limite la mémoire consommée.
///
/// Le verrouillage couvre cet arbre sans le démonter. Les présentations,
/// positions de défilement et piles survivent au passage en arrière-plan.
struct MainTabView: View {
    let drive: Drive
    let session: SessionStore

    /// Navigation possédée par la session, remplacée au changement de drive.
    let shell: MainTabShellState
    @State private var showUploadSheet = false
    /// Hauteur mesurée des pastilles superposées à la barre d'onglets (bandeau
    /// de téléchargement + pilule d'upload). Zéro quand rien n'est affiché : la
    /// barre et les grilles gardent alors exactement leur apparence actuelle.
    @State private var overlayChromeHeight: CGFloat = 0
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true

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
        ZStack(alignment: .bottom) {
            tabs
                // Réserve exactement la place des pastilles flottant au-dessus
                // de la barre : sans cela, elles recouvraient le bouton « + »
                // et la dernière rangée des grilles, dont les marges basses
                // sont calibrées pour la barre seule. Mesurée (et non
                // devinée) : elle suit la taille réelle du texte (Dynamic
                // Type) et s'anime avec l'apparition des pastilles.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: max(0, overlayChromeHeight))
                        .animation(.snappy(duration: 0.28), value: overlayChromeHeight)
                }

            VStack(spacing: 0) {
                TransferOverlayChrome(
                    uploadManager: uploadManager,
                    onShowUploads: { showUploadSheet = true },
                    onHeightChange: { overlayChromeHeight = $0 }
                )

                FloatingTabBar(
                    selection: $shell.tab,
                    onSelect: { targetTab in
                        guard targetTab == .profile else { return }
                        // Démarre au clic, avant que ProfileView soit montée.
                        // Sa propre tâche rejoint ensuite la même requête.
                        Task {
                            await RecentUploadsLoader.shared.prefetch(driveId: drive.id)
                        }
                    },
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(.accentColor)
        .sheet(isPresented: $showUploadSheet) {
            UploadProgressSheet(manager: uploadManager)
        }
        .fullScreenCover(item: $shell.router.mediaContext) { context in
            MediaPagerView(context: context)
        }
        .fullScreenCover(item: $shell.router.textFile) { file in
            TextFileViewer(file: file, driveId: drive.id)
        }
    }

    @ViewBuilder
    private var tabs: some View {
        // Même pattern que `body` : bindings vers l'état persistant.
        @Bindable var shell = shell
        ZStack {
            tabPane(.settings) {
                SettingsView(session: session, path: $shell.navState.settingsPath)
            }
            tabPane(.tag) {
                TagsView(
                    driveId: drive.id,
                    router: shell.router,
                    path: $shell.navState.tagsPath,
                    trail: $shell.navState.tagsTrail
                )
            }
            tabPane(.home) {
                HomeTab(
                    driveId: drive.id,
                    router: shell.router,
                    isSelected: shell.tab == .home,
                    path: $shell.navState.homePath
                )
            }
            tabPane(.favorites) {
                FavoritesView(
                    driveId: drive.id,
                    router: shell.router,
                    path: $shell.navState.favoritesPath,
                    scrollToTopRequest: shell.navState.favoritesScrollToTopRequest
                )
            }
            tabPane(.profile) {
                ProfileView(
                    session: session,
                    router: shell.router,
                    path: $shell.navState.profilePath,
                    isSelected: shell.tab == .profile,
                    refreshRequest: shell.navState.profileRefreshRequest
                )
            }
        }
    }

    @ViewBuilder
    private func tabPane(_ target: AppTab, @ViewBuilder content: () -> some View) -> some View {
        // Seul l'Accueil reste monté en permanence (état de scroll et données
        // conservés) ; les autres onglets ne sont montés que lorsqu'ils sont
        // sélectionnés, ce qui libère leurs vues à chaque changement d'onglet.
        if target == .home || target == shell.tab {
            content()
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
    let onHeightChange: (CGFloat) -> Void

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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .animation(.snappy(duration: 0.28), value: uploadManager.isPillVisible)
        .animation(.snappy(duration: 0.28), value: downloadService.isDownloading)
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

            Button("Annuler", action: onCancel)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingChrome(Capsule())
        .padding(.horizontal, DS.gridMargin + 8)
        .accessibilityLabel("Téléchargement en cours")
    }
}
