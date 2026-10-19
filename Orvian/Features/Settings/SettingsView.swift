import SwiftUI

/// Hub de réglages : apparence, médias, stockage local et sécurité.
struct SettingsView: View {
    let session: SessionStore
    @Binding var path: NavigationPath
    @Binding var selectedSpace: SettingsRoute?
    /// Visibilité de la colonne de gauche (bouton de masquage de l'en-tête).
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Environment(\.iPadLayout) private var iPadLayout

    @State private var cacheSize: Int = 0
    @State private var showSignOutConfirm = false

    @AppStorage("showFileSizes") private var showFileSizes = true
    @AppStorage("showFavoriteStars") private var showFavoriteStars = true
    @AppStorage("phoneFileGridColumns") private var phoneColumns = 3
    @AppStorage("padFileGridDensity") private var padDensity = 3
    private var fileGridColumns: Int { iPadLayout.isPad ? padDensity : min(3, max(2, phoneColumns)) }
    private var gridColumnsBinding: Binding<Int> {
        Binding(get: { fileGridColumns }, set: { if iPadLayout.isPad { padDensity = $0 } else { phoneColumns = $0 } })
    }
    @AppStorage("tagGridColumns") private var tagGridColumns = 2
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false
    @AppStorage("showBreadcrumb") private var showBreadcrumb = true
    @AppStorage("foldersFirstInTags") private var foldersFirstInTags = true
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true
    @AppStorage("prefetchThumbnails") private var prefetchThumbnails = true
    @AppStorage("prefetchVideoURLs") private var prefetchVideoURLs = true
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = true
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB = 250
    @AppStorage("networkCacheLimitMB") private var networkCacheLimitMB = 100
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"
    @AppStorage(PerfTimer.settingsKey) private var networkPerfEnabled = true

    @State private var isLockCodeEnabled = AppLockStore.isConfigured
    @State private var showActivateCode = false
    @State private var showChangeCode = false
    @State private var showDisableCode = false

    var body: some View {
        Group {
            if iPadLayout.isPad {
                padNavigation
            } else {
                phoneNavigation
            }
        }
        .sheet(isPresented: $showActivateCode, onDismiss: refreshLockState) {
            AppLockSetupSheet(flow: .activate)
        }
        .sheet(isPresented: $showChangeCode, onDismiss: refreshLockState) {
            AppLockSetupSheet(flow: .change)
        }
        .sheet(isPresented: $showDisableCode, onDismiss: refreshLockState) {
            AppLockSetupSheet(flow: .disable)
        }
        .confirmationDialog("Se déconnecter ?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
                session.signOut()
            }
        } message: {
            Text("Le token et le drive sélectionné seront effacés de cet appareil.")
        }
        .task {
            cacheSize = await ThumbnailProvider.shared.diskCacheSize()
        }
        .onChange(of: prefetchThumbnails) { _, enabled in
            guard !enabled else { return }
            Task { await ThumbnailProvider.shared.cancelPrefetch() }
        }
        .onChange(of: prefetchVideoURLs) { _, enabled in
            guard !enabled else { return }
            Task { await VideoAssetCache.shared.cancelPrefetch() }
        }
        .onChange(of: prefetchOnWiFiOnly) { _, enabled in
            guard enabled else { return }
            Task {
                await ThumbnailProvider.shared.cancelPrefetch()
                await VideoAssetCache.shared.cancelPrefetch()
            }
        }
        .onChange(of: thumbnailCacheLimitMB) { _, _ in
            Task {
                await ThumbnailProvider.shared.enforceDiskLimit()
                cacheSize = await ThumbnailProvider.shared.diskCacheSize()
            }
        }
        // Le cache réseau est de taille fixe : la session est reconstruite
        // autour d'un URLCache redimensionné, sans toucher aux requêtes en vol.
        .onChange(of: networkCacheLimitMB) { _, _ in
            Task { await APIClient.shared.applyCacheSettings() }
        }
    }

    // MARK: - Navigation

    private var phoneNavigation: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Text("Réglages")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, DS.gridMargin)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                List {
                    destinationsSection
                    aboutSection
                }
                .listStyle(.insetGrouped)
                .contentMargins(.top, 12, for: .scrollContent)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsRoute.self) { route in
                destinationView(for: route)
                    .toolbar(.visible, for: .navigationBar)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: DS.contentBottomInset)
            }
        }
    }

    private var padNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                // Un seul en-tête, dans la zone de sécurité de la colonne.
                PadSidebarHeader(title: Text("Réglages"), columnVisibility: $columnVisibility) {
                    EmptyView()
                }

                List(selection: $selectedSpace) {
                    destinationsSection
                    aboutSection
                }
                .listStyle(.sidebar)
                .navigationTitle("Réglages")
                .scrollContentBackground(.hidden)
                // Couleur de page de l'app. Le matériau de barre latérale rend
                // ≈ `secondarySystemGroupedBackground`, la couleur de *carte* :
                // la colonne lisait donc comme une carte géante collée au détail.
                // Aucune réserve basse : la barre d'onglets native de l'iPad
                // insère déjà son espace ; `DS.floatingBarInset` (barre flottante
                // iPhone) ne laissait qu'une bande vide sous la liste.
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            Group {
                if let selectedSpace {
                    destinationView(for: selectedSpace)
                } else {
                    EmptyStateView(symbol: "slider.horizontal.3", title: "Réglages",
                                   message: "Choisissez un espace dans la liste.")
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Espaces de réglages

    private var destinationsSection: some View {
        Section {
            SettingsLinkRow(
                icon: "paintbrush.fill",
                title: "Apparence et navigation",
                summary: appearanceSummary,
                tint: .indigo,
                route: .appearance
            )
            SettingsLinkRow(
                icon: "photo.stack",
                title: "Médias et réseau",
                summary: mediaSummary,
                tint: .blue,
                route: .media
            )
            SettingsLinkRow(
                icon: "internaldrive.fill",
                title: "Stockage",
                summary: storageSummary,
                tint: .green,
                route: .storage
            )
            SettingsLinkRow(
                icon: "lock.shield.fill",
                title: "Sécurité",
                summary: securitySummary,
                tint: .orange,
                route: .security,
                showsDot: !isLockCodeEnabled
            )
        } header: {
            // Sur iPad, le titre de la colonne dit déjà « Réglages » et les
            // textes d'aide d'une barre latérale se lisent comme du contenu.
            if !iPadLayout.isPad {
                Text("Préférences")
            }
        } footer: {
            if !iPadLayout.isPad {
                Text("Chaque espace regroupe les options qui vont ensemble.")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !iPadLayout.isPad {
                NavigationLink {
                    PerfView()
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    Label("Mesures réseau", systemImage: "gauge.with.dots")
                }
                if let drive = session.selectedDrive {
                    NavigationLink {
                        ThumbnailInformationView(driveId: drive.id)
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        Label("Miniatures", systemImage: "photo.on.rectangle")
                    }
                }
            }
        } header: {
            Text(iPadLayout.isPad ? "À propos" : "Informations et diagnostics")
        } footer: {
            if !iPadLayout.isPad {
                Text("Orvian conserve le token et le drive choisi uniquement sur cet appareil.")
            }
        }
    }

    // MARK: - Résumés d'état (évitent d'entrer pour comprendre)

    private var appearanceSummary: String {
        "\(fileGridColumns) cartes par ligne · Tags \(tagGridColumns) col."
    }

    private var mediaSummary: String {
        if !prefetchThumbnails && !prefetchVideoURLs { return "Préchargement coupé" }
        return prefetchOnWiFiOnly ? "Précharge en Wi-Fi" : "Précharge toujours"
    }

    private var storageSummary: String {
        let limit = thumbnailCacheLimitMB == 0 ? "sans limite" : "max \(thumbnailCacheLimitMB >= 1_024 ? "1 Go" : "\(thumbnailCacheLimitMB) Mo")"
        return "\(ByteFormatter.string(fromBytes: cacheSize)) · \(limit)"
    }

    private var securitySummary: String {
        isLockCodeEnabled ? "Verrouillage actif" : "Aucun code exigé"
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destinationView(for route: SettingsRoute) -> some View {
        switch route {
        case .appearance:
            AppearanceSpace(
                showFileSizes: $showFileSizes,
                showFavoriteStars: $showFavoriteStars,
                fileGridColumns: gridColumnsBinding,
                tagGridColumns: $tagGridColumns,
                foldersFirstInTags: $foldersFirstInTags,
                alwaysShowSearch: $alwaysShowSearch,
                showBreadcrumb: $showBreadcrumb,
                favoritesReselectScrollToTop: $favoritesReselectScrollToTop,
                hapticFeedbackEnabled: $hapticFeedbackEnabled,
                defaultFolderColor: defaultFolderColorBinding
            )
        case .media:
            MediaSpace(
                prefetchThumbnails: $prefetchThumbnails,
                prefetchVideoURLs: $prefetchVideoURLs,
                prefetchOnWiFiOnly: $prefetchOnWiFiOnly,
                networkPerfEnabled: $networkPerfEnabled
            )
        case .storage:
            StorageSpace(
                cacheSize: cacheSize,
                limitMB: $thumbnailCacheLimitMB,
                networkLimitMB: $networkCacheLimitMB,
                onPurge: purgeCache
            )
        case .security:
            SecuritySpace(
                session: session,
                isEnabled: isLockCodeEnabled,
                onActivate: { showActivateCode = true },
                onChange: { showChangeCode = true },
                onDisable: { showDisableCode = true },
                onSignOut: { showSignOutConfirm = true }
            )
        }
    }

    // MARK: - Actions partagées

    private func refreshLockState() {
        isLockCodeEnabled = AppLockStore.isConfigured
    }

    private func purgeCache() {
        Task {
            await ThumbnailProvider.shared.purgeDiskCache()
            cacheSize = await ThumbnailProvider.shared.diskCacheSize()
        }
    }

    private var defaultFolderColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: defaultFolderColor) ?? FileKind.folder.tint },
            set: { defaultFolderColor = $0.toHex() ?? "#4285F5" }
        )
    }
}

// MARK: - Briques du hub

/// Ligne de destination : icône teintée, titre, résumé d'état live.
private struct SettingsLinkRow: View {
    let icon: String
    let title: String
    let summary: String
    let tint: Color
    let route: SettingsRoute
    var showsDot = false
    @Environment(\.iPadLayout) private var iPadLayout

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                HubIcon(icon, tint: tint)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                        if showsDot {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                                .accessibilityLabel("Action recommandée")
                        }
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Une liste ne pose qu'une hauteur minimale : sur iPad, ce
            // rembourrage vertical règle l'air des lignes de la barre latérale.
            .padding(.vertical, iPadLayout.isPad ? 10 : 2)
        }
        .tag(route)
    }
}

private struct HubIcon: View {
    let name: String
    let tint: Color
    var size: CGFloat = 32

    init(_ name: String, tint: Color, size: CGFloat = 32) {
        self.name = name
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Espace 1 : Apparence et navigation

private struct AppearanceSpace: View {
    @Environment(\.iPadLayout) private var iPadLayout
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @AppStorage("iPadTabBarAtBottom") private var iPadTabBarAtBottom = false
    @AppStorage("padFilterMenuScale") private var padFilterMenuScale = 1.2
    @Binding var showFileSizes: Bool
    @Binding var showFavoriteStars: Bool
    @Binding var fileGridColumns: Int
    @Binding var tagGridColumns: Int
    @Binding var foldersFirstInTags: Bool
    @Binding var alwaysShowSearch: Bool
    @Binding var showBreadcrumb: Bool
    @Binding var favoritesReselectScrollToTop: Bool
    @Binding var hapticFeedbackEnabled: Bool
    @Binding var defaultFolderColor: Color

    var body: some View {
        List {
            Section {
                Picker("Apparence", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Text("Thème")
            } footer: {
                Text("Système suit l’apparence de l’appareil. Le choix est conservé sur cet appareil, sur iPhone comme sur iPad.")
            }
            if iPadLayout.isPad {
                Section {
                    Toggle("Barre d’onglets en bas", isOn: $iPadTabBarAtBottom)
                } header: {
                    Text("Navigation iPad")
                } footer: {
                    Text("Centre la barre en bas et libère la bande supérieure pour les barres latérales. Le changement est immédiat.")
                }
                Section("Menu des filtres iPad") {
                    Picker("Taille du menu et des éléments", selection: $padFilterMenuScale) {
                        ForEach(11...15, id: \.self) { value in
                            Text("×1.\(value - 10)").tag(Double(value) / 10)
                        }
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper(value: $fileGridColumns, in: 2...(iPadLayout.isPad ? 7 : 3)) {
                        HStack {
                            Text("Densité des miniatures")
                            Spacer()
                            Text(iPadLayout.isPad ? "\(fileGridColumns - 1) / 6" : "\(fileGridColumns) colonnes")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 4)

                Stepper(value: $tagGridColumns, in: 2...3) {
                    HStack {
                        Text(iPadLayout.isPad ? "Colonnes des tags sur iPhone" : "Colonnes des tags")
                        Spacer()
                        Text("\(tagGridColumns)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Densité")
            } footer: {
                Text(iPadLayout.isPad
                      ? "De 1 (grandes) à 6 (petites). Le nombre réel dépend de la largeur et de la taille du texte. Le réglage des tags concerne l’iPhone."
                      : "De 1 (grandes) à 6 (petites). Le nombre de colonnes est limité pour conserver des cartes lisibles.")
            }

            Section("Informations visibles") {
                Toggle("Poids des fichiers", isOn: $showFileSizes)
                Toggle("Étoiles des favoris", isOn: $showFavoriteStars)
                Toggle("Chemin du dossier", isOn: $showBreadcrumb)
                Toggle("Recherche toujours visible", isOn: $alwaysShowSearch)
            }

            Section {
                Toggle("Dossiers en premier (tags)", isOn: $foldersFirstInTags)
                Toggle(iPadLayout.isPad ? "Retour en haut des favoris sur iPhone" : "Revenir en haut (favoris)", isOn: $favoritesReselectScrollToTop)
                HStack {
                    Text("Couleur des dossiers")
                    Spacer()
                    ColorPicker("Couleur des dossiers", selection: $defaultFolderColor, supportsOpacity: false)
                        .labelsHidden()
                }
            } header: {
                Text("Organisation")
            } footer: {
                Text("La couleur s'applique aux dossiers sans couleur personnalisée.")
            }

            Section {
                Toggle("Retours haptiques", isOn: $hapticFeedbackEnabled)
            } header: {
                Text("Confort")
            } footer: {
                Text("Une légère vibration accompagne les changements d'onglet.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: DS.contentBottomInset)
        }
        .navigationTitle("Apparence")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Espace 2 : Médias et réseau

private struct MediaSpace: View {
    @Environment(\.iPadLayout) private var iPadLayout
    @Binding var prefetchThumbnails: Bool
    @Binding var prefetchVideoURLs: Bool
    @Binding var prefetchOnWiFiOnly: Bool
    @Binding var networkPerfEnabled: Bool

    var body: some View {
        List {
            Section {
                Toggle(isOn: $prefetchThumbnails) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Miniatures")
                            Text("Galeries instantanées")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { HubIcon("photo.stack", tint: .pink) }
                }
                Toggle(isOn: $prefetchVideoURLs) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vidéos")
                            Text("Lecture sans attente")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { HubIcon("play.rectangle.fill", tint: .purple) }
                }
            } header: {
                Text("Préchargement")
            } footer: {
                Text("Anticipe les contenus autour de ce que vous regardez.")
            }

            Section {
                Toggle("Wi-Fi uniquement", isOn: $prefetchOnWiFiOnly)
                    .disabled(!prefetchThumbnails && !prefetchVideoURLs)
            } header: {
                Text("Données mobiles")
            } footer: {
                Text("Recommandé si votre forfait est limité.")
            }

            Section {
                Toggle("Suivi des requêtes réseau", isOn: $networkPerfEnabled)
            } header: {
                Text("Diagnostic")
            } footer: {
                Text("Journal des durées et codes HTTP, consultable dans Profil → Mesures réseau. Désactivé, rien n'est collecté.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: DS.contentBottomInset)
        }
        .navigationTitle("Médias et réseau")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Espace 3 : Stockage

private struct StorageSpace: View {
    @Environment(\.iPadLayout) private var iPadLayout
    let cacheSize: Int
    @Binding var limitMB: Int
    @Binding var networkLimitMB: Int
    let onPurge: () -> Void

    var body: some View {
        List {
            Section("Cache des miniatures") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(ByteFormatter.string(fromBytes: cacheSize))
                            .font(.title2.weight(.bold).monospacedDigit())
                        Spacer()
                        Text(limitLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    cacheGauge
                    Text("Les miniatures sont conservées temporairement pour accélérer l'affichage.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Picker("Limite automatique", selection: $limitMB) {
                    Text("250 Mo").tag(250)
                    Text("500 Mo").tag(500)
                    Text("1 Go").tag(1_024)
                    Text("Sans limite").tag(0)
                }
            }

            Section("Cache réseau") {
                Picker("Cache réseau", selection: $networkLimitMB) {
                    Text("25 Mo").tag(25); Text("50 Mo").tag(50)
                    Text("100 Mo").tag(100); Text("250 Mo").tag(250)
                    Text("Désactivé sur disque").tag(0)
                }
            }

            Section {
                Button("Vider le cache", role: .destructive, action: onPurge)
            } footer: {
                Text("Sans danger : les miniatures seront retéléchargées à la demande.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: DS.contentBottomInset)
        }
        .navigationTitle("Stockage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var limitLabel: String {
        limitMB == 0 ? "Sans limite" : "Max \(limitMB >= 1_024 ? "1 Go" : "\(limitMB) Mo")"
    }

    private var cacheGauge: some View {
        let ratio: Double = limitMB == 0 ? 0.1 : min(1, Double(cacheSize) / Double(max(limitMB, 1) * 1_048_576))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 8)
                Capsule()
                    .fill(ratio > 0.85 ? .orange : .green)
                    .frame(width: proxy.size.width * max(0.04, ratio), height: 8)
                    .animation(Motion.animation(.snappy), value: ratio)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Cache utilisé")
    }
}

// MARK: - Espace 4 : Sécurité

private struct SecuritySpace: View {
    let session: SessionStore
    let isEnabled: Bool
    let onActivate: () -> Void
    let onChange: () -> Void
    let onDisable: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    HubIcon(isEnabled ? "lock.fill" : "lock.open.fill", tint: isEnabled ? .green : .orange, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isEnabled ? "Verrouillage actif" : "Verrouillage coupé")
                            .font(.headline)
                        Text(isEnabled ? "Code exigé à chaque ouverture" : "N'importe qui ouvrant l'app accède au drive")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(isEnabled ? "ON" : "OFF")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(isEnabled ? .green : .orange, in: Capsule())
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Le code et Face ID protègent l'accès local. Le token reste sur l'appareil.")
            }

            Section("Code") {
                if isEnabled {
                    Button { onChange() } label: {
                        Label("Modifier le code", systemImage: "pencil")
                    }
                    Button(role: .destructive) { onDisable() } label: {
                        Label("Désactiver le code", systemImage: "lock.open")
                    }
                } else {
                    Button { onActivate() } label: {
                        Label("Activer le code de verrouillage", systemImage: "lock.fill")
                    }
                }
            }

            if session.usesTemporaryCredentials {
                Section {
                    Label("Connexion temporaire : le stockage sécurisé est indisponible. Vous devrez vous reconnecter après avoir quitté l'app.", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section {
                Button(role: .destructive, action: onSignOut) {
                    Label("Changer de token / se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } header: {
                Text("Session")
            } footer: {
                Text("Le token et le drive choisi sont enregistrés uniquement sur cet appareil.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: DS.contentBottomInset)
        }
        .navigationTitle("Sécurité")
        .navigationBarTitleDisplayMode(.inline)
    }
}
