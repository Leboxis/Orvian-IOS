import SwiftUI

/// Hub de réglages : fini la liste infinie de cartes.
///
/// Avant : un seul scroll de ~25 interrupteurs au même niveau, 9 cartes
/// custom, icônes arc-en-ciel, Drive en haut et Compte tout en bas.
///
/// Après : un écran d'accueil court qui répond à « où suis-je / que puis-je
/// changer ? », puis 5 espaces dédiés poussés dans la pile :
/// Apparence · Médias & réseau · Stockage · Sécurité · Compte.
/// Chaque ligne du hub affiche un résumé d'état live, et une recherche
/// instantanée expose directement le réglage cherché sans naviguer.
struct SettingsView: View {
    let session: SessionStore
    @Binding var path: NavigationPath

    @State private var searchText = ""
    @State private var cacheSize: Int = 0
    @State private var showDrivePicker = false
    @State private var showSignOutConfirm = false

    @AppStorage("showFileSizes") private var showFileSizes = true
    @AppStorage("showFavoriteStars") private var showFavoriteStars = true
    @AppStorage("fileGridColumns") private var fileGridColumns = 3
    @AppStorage("tagGridColumns") private var tagGridColumns = 2
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false
    @AppStorage("showBreadcrumb") private var showBreadcrumb = true
    @AppStorage("foldersFirstInTags") private var foldersFirstInTags = true
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true
    @AppStorage("prefetchThumbnails") private var prefetchThumbnails = true
    @AppStorage("prefetchVideoURLs") private var prefetchVideoURLs = true
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = true
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB = 250
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true
    @AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"
    @AppStorage(PerfTimer.settingsKey) private var networkPerfEnabled = true

    @State private var isLockCodeEnabled = AppLockStore.isConfigured
    @State private var showActivateCode = false
    @State private var showChangeCode = false
    @State private var showDisableCode = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    accountHeaderSection
                    quickAccessSection
                    destinationsSection
                    aboutSection
                } else {
                    searchResultsSection
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Rechercher un réglage")
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: SettingsRoute.self) { route in
                destinationView(for: route)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 90)
            }
        }
        .sheet(isPresented: $showDrivePicker) {
            DrivePickerSheet(session: session)
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
    }

    // MARK: - Hub : en-tête compte

    private var accountHeaderSection: some View {
        Section {
            Button {
                path.append(SettingsRoute.account)
            } label: {
                HStack(spacing: 14) {
                    avatarView
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.selectedDrive?.name ?? "Mon drive")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if session.usesTemporaryCredentials {
                            Label("Session temporaire", systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        } else if isLockCodeEnabled {
                            Label("Protégé par code", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Compte connecté sur cet appareil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let drive = session.selectedDrive {
                            quotaBar(drive)
                                .padding(.top, 6)
                        }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    private var avatarView: some View {
        let initial = session.selectedDrive?.name.first.map(String.init) ?? "O"
        return Text(initial.uppercased())
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(
                LinearGradient(
                    colors: [.accentColor, .accentColor.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .accessibilityHidden(true)
    }

    private func quotaBar(_ drive: Drive) -> some View {
        let used = Double(drive.usedSize ?? 0)
        let total = Double(max(drive.size ?? 1, 1))
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 6)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * min(1, used / total), height: 6)
                }
            }
            .frame(height: 6)
            Text(ByteFormatter.usage(used: drive.usedSize, total: drive.size))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hub : accès rapide

    private var quickAccessSection: some View {
        Section("Accès rapide") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                QuickTile(
                    icon: "photo.stack",
                    title: "Médias",
                    status: mediaSummary,
                    tint: .blue
                ) { path.append(SettingsRoute.media) }
                QuickTile(
                    icon: "internaldrive.fill",
                    title: "Stockage",
                    status: ByteFormatter.string(fromBytes: cacheSize),
                    tint: .green
                ) { path.append(SettingsRoute.storage) }
                QuickTile(
                    icon: "lock.fill",
                    title: "Sécurité",
                    status: isLockCodeEnabled ? "Activée" : "Coupée",
                    tint: isLockCodeEnabled ? .green : .orange
                ) { path.append(SettingsRoute.security) }
                QuickTile(
                    icon: "square.grid.2x2",
                    title: "Affichage",
                    status: "\(fileGridColumns) / ligne",
                    tint: .indigo
                ) { path.append(SettingsRoute.appearance) }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Hub : destinations

    private var destinationsSection: some View {
        Section("Personnaliser") {
            DestinationRow(
                icon: "paintbrush.fill",
                title: "Apparence et navigation",
                subtitle: appearanceSummary,
                tint: .indigo,
                route: .appearance
            )
            DestinationRow(
                icon: "play.rectangle.fill",
                title: "Médias et réseau",
                subtitle: mediaSummary,
                tint: .blue,
                route: .media
            )
            DestinationRow(
                icon: "internaldrive.fill",
                title: "Stockage local",
                subtitle: storageSummary,
                tint: .green,
                route: .storage
            )
            DestinationRow(
                icon: "lock.shield.fill",
                title: "Sécurité",
                subtitle: isLockCodeEnabled ? "Code exigé à l'ouverture" : "Aucun code exigé",
                tint: .orange,
                route: .security,
                showsDot: !isLockCodeEnabled
            )
            DestinationRow(
                icon: "person.circle.fill",
                title: "Compte et drive",
                subtitle: session.selectedDrive?.name ?? "—",
                tint: .teal,
                route: .account
            )
        } footer: {
            Text("Chaque espace regroupe les options qui vont ensemble. Rien n'est perdu : tout l'ancien contenu est réparti dans ces 5 espaces.")
        }
    }

    private var aboutSection: some View {
        Section("À propos") {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Orvian conserve le token et le drive choisi uniquement sur cet appareil.")
        }
    }

    // MARK: - Résumés d'état (évitent d'entrer pour comprendre)

    private var appearanceSummary: String {
        "\(fileGridColumns)/ligne · Tags \(tagGridColumns) col."
    }

    private var mediaSummary: String {
        if !prefetchThumbnails && !prefetchVideoURLs { return "Préchargement coupé" }
        return prefetchOnWiFiOnly ? "Précharge en Wi-Fi" : "Précharge toujours"
    }

    private var storageSummary: String {
        let limit = thumbnailCacheLimitMB == 0 ? "sans limite" : "max \(thumbnailCacheLimitMB >= 1_024 ? "1 Go" : "\(thumbnailCacheLimitMB) Mo")"
        return "\(ByteFormatter.string(fromBytes: cacheSize)) · \(limit)"
    }

    // MARK: - Recherche instantanée : le réglage répond directement

    private func matches(_ haystacks: String...) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return haystacks.joined(separator: " ").lowercased().contains(q)
    }

    private var searchResultsSection: some View {
        Section("Résultats") {
            if matches("poids taille afficher fichiers") {
                Toggle("Afficher le poids des fichiers", isOn: $showFileSizes)
            }
            if matches("étoile favoris star") {
                Toggle("Étoiles des favoris", isOn: $showFavoriteStars)
            }
            if matches("cartes ligne grille colonnes densité") {
                Picker("Cartes par ligne", selection: $fileGridColumns) {
                    ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            if matches("tags colonnes") {
                Picker("Colonnes des tags", selection: $tagGridColumns) {
                    Text("2").tag(2); Text("3").tag(3)
                }
            }
            if matches("dossiers premier tags tri") {
                Toggle("Dossiers en premier (tags)", isOn: $foldersFirstInTags)
            }
            if matches("recherche loupe visible") {
                Toggle("Recherche toujours visible", isOn: $alwaysShowSearch)
            }
            if matches("chemin breadcrumb fil ariane") {
                Toggle("Afficher le chemin du dossier", isOn: $showBreadcrumb)
            }
            if matches("couleur dossier défaut") {
                ColorPicker("Couleur des dossiers", selection: defaultFolderColorBinding, supportsOpacity: false)
            }
            if matches("favoris haut retour scroll") {
                Toggle("Revenir en haut (favoris)", isOn: $favoritesReselectScrollToTop)
            }
            if matches("miniatures précharger photos") {
                Toggle("Précharger les miniatures", isOn: $prefetchThumbnails)
            }
            if matches("vidéos précharger") {
                Toggle("Précharger les vidéos", isOn: $prefetchVideoURLs)
            }
            if matches("wifi wi-fi données mobiles") {
                Toggle("Wi-Fi uniquement", isOn: $prefetchOnWiFiOnly)
            }
            if matches("cache limite stockage mo go") {
                Picker("Limite du cache", selection: $thumbnailCacheLimitMB) {
                    Text("250 Mo").tag(250); Text("500 Mo").tag(500)
                    Text("1 Go").tag(1_024); Text("Sans limite").tag(0)
                }
            }
            if matches("vider cache effacer") {
                Button("Vider le cache", role: .destructive) { purgeCache() }
            }
            if matches("haptique vibration confort") {
                Toggle("Retours haptiques", isOn: $hapticFeedbackEnabled)
            }
            if matches("réseau diagnostic requêtes suivi perf") {
                Toggle("Suivi des requêtes réseau", isOn: $networkPerfEnabled)
            }
            if matches("code verrouillage sécurité lock face id") {
                Button(isLockCodeEnabled ? "Gérer le code…" : "Activer le code…") {
                    path.append(SettingsRoute.security)
                }
            }
            if matches("compte token déconnecter drive changer") {
                Button("Ouvrir Compte et drive…") {
                    path.append(SettingsRoute.account)
                }
            }
        } footer: {
            Text("Tapez « cache », « code », « grille »… le réglage s'affiche ici sans ouvrir d'écran.")
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destinationView(for route: SettingsRoute) -> some View {
        switch route {
        case .appearance:
            AppearanceSpace(
                showFileSizes: $showFileSizes,
                showFavoriteStars: $showFavoriteStars,
                fileGridColumns: $fileGridColumns,
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
                onPurge: purgeCache
            )
        case .security:
            SecuritySpace(
                isEnabled: isLockCodeEnabled,
                onActivate: { showActivateCode = true },
                onChange: { showChangeCode = true },
                onDisable: { showDisableCode = true }
            )
        case .account:
            AccountSpace(
                session: session,
                onChangeDrive: { showDrivePicker = true },
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

// MARK: - Routage

private enum SettingsRoute: Hashable {
    case appearance, media, storage, security, account
}

// MARK: - Briques du hub

private struct DestinationRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let route: SettingsRoute
    var showsDot = false

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
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct QuickTile: View {
    let icon: String
    let title: String
    let status: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HubIcon(icon, tint: tint, size: 36)
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
            Section("Densité") {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper(value: $fileGridColumns, in: 2...7) {
                        HStack {
                            Text("Cartes par ligne")
                            Spacer()
                            Text("\(fileGridColumns)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    // Aperçu vivant : la densité se comprend d'un coup d'œil.
                    HStack(spacing: 6) {
                        ForEach(0..<fileGridColumns, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.25))
                                .frame(height: 44)
                        }
                    }
                    .animation(.snappy, value: fileGridColumns)
                    .accessibilityHidden(true)
                }
                .padding(.vertical, 4)

                Stepper(value: $tagGridColumns, in: 2...3) {
                    HStack {
                        Text("Colonnes des tags")
                        Spacer()
                        Text("\(tagGridColumns)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("Moins de cartes = plus grandes miniatures. L'aperçu ci-dessus suit votre choix.")
            }

            Section("Informations visibles") {
                Toggle("Poids des fichiers", isOn: $showFileSizes)
                Toggle("Étoiles des favoris", isOn: $showFavoriteStars)
                Toggle("Chemin du dossier", isOn: $showBreadcrumb)
                Toggle("Recherche toujours visible", isOn: $alwaysShowSearch)
            }

            Section("Organisation") {
                Toggle("Dossiers en premier (tags)", isOn: $foldersFirstInTags)
                Toggle("Revenir en haut (favoris)", isOn: $favoritesReselectScrollToTop)
                HStack {
                    Text("Couleur des dossiers")
                    Spacer()
                    ColorPicker("Couleur des dossiers", selection: $defaultFolderColor, supportsOpacity: false)
                        .labelsHidden()
                }
            } footer: {
                Text("La couleur s'applique aux dossiers sans couleur personnalisée.")
            }

            Section("Confort") {
                Toggle("Retours haptiques", isOn: $hapticFeedbackEnabled)
            } footer: {
                Text("Une légère vibration accompagne les changements d'onglet.")
            }
        }
        .navigationTitle("Apparence")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Espace 2 : Médias et réseau

private struct MediaSpace: View {
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

            Section("Données mobiles") {
                Toggle("Wi-Fi uniquement", isOn: $prefetchOnWiFiOnly)
                    .disabled(!prefetchThumbnails && !prefetchVideoURLs)
            } footer: {
                Text("Recommandé si votre forfait est limité.")
            }

            Section("Diagnostic") {
                Toggle("Suivi des requêtes réseau", isOn: $networkPerfEnabled)
            } footer: {
                Text("Journal des durées et codes HTTP, consultable dans Profil → Mesures réseau. Désactivé, rien n'est collecté.")
            }
        }
        .navigationTitle("Médias et réseau")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Espace 3 : Stockage

private struct StorageSpace: View {
    let cacheSize: Int
    @Binding var limitMB: Int
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

            Section {
                Button("Vider le cache", role: .destructive, action: onPurge)
            } footer: {
                Text("Sans danger : les miniatures seront retéléchargées à la demande.")
            }
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
                    .animation(.snappy, value: ratio)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Cache utilisé")
    }
}

// MARK: - Espace 4 : Sécurité

private struct SecuritySpace: View {
    let isEnabled: Bool
    let onActivate: () -> Void
    let onChange: () -> Void
    let onDisable: () -> Void

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
        }
        .navigationTitle("Sécurité")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Espace 5 : Compte et drive

private struct AccountSpace: View {
    let session: SessionStore
    let onChangeDrive: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        List {
            if let drive = session.selectedDrive {
                Section("Drive actuel") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(drive.name).font(.headline)
                        Text(ByteFormatter.usage(used: drive.usedSize, total: drive.size))
                            .font(.subheadline).foregroundStyle(.secondary)
                        ProgressView(value: Double(drive.usedSize ?? 0), total: Double(max(drive.size ?? 1, 1)))
                            .tint(.accentColor)
                    }
                    .padding(.vertical, 4)
                    if session.drives.count > 1 {
                        Button("Changer de drive…", action: onChangeDrive)
                    }
                }
            }

            if session.usesTemporaryCredentials {
                Section {
                    Label("Connexion temporaire : le stockage sécurisé est indisponible. Vous devrez vous reconnecter après avoir quitté l'app.", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section("Session") {
                Button(role: .destructive, action: onSignOut) {
                    Label("Changer de token / se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                Text("Le token et le drive choisi sont enregistrés uniquement sur cet appareil.")
            }
        }
        .navigationTitle("Compte")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Sélection du drive quand le compte en possède plusieurs.
private struct DrivePickerSheet: View {
    let session: SessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(session.drives) { drive in
                Button {
                    session.selectDrive(drive)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drive.name)
                            Text(ByteFormatter.usage(used: drive.usedSize, total: drive.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if drive.id == session.selectedDrive?.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choisir un drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
