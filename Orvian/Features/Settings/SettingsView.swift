import SwiftUI

/// Espace de préférences organisé par usages, avec des réglages faciles à parcourir.
struct SettingsView: View {
    let session: SessionStore
    @Binding var path: NavigationPath

    @State private var cacheSize: Int = 0
    @State private var showDrivePicker = false
    @State private var showSignOutConfirm = false
    @AppStorage("showFileSizes") private var showFileSizes = true
    @AppStorage("fileGridColumns") private var fileGridColumns = 3
    @AppStorage("tagGridColumns") private var tagGridColumns = 2
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false
    @AppStorage("foldersFirstInTags") private var foldersFirstInTags = true
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true
    @AppStorage("prefetchThumbnails") private var prefetchThumbnails = true
    @AppStorage("prefetchVideoURLs") private var prefetchVideoURLs = true
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = false
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
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let drive = session.selectedDrive {
                        driveSummary(drive)
                    }

                    settingsCard(
                        title: "Interface",
                        message: "Adaptez l’affichage et la navigation à votre façon d’utiliser Orvian.",
                        icon: "paintbrush.fill",
                        tint: .indigo
                    ) {
                        settingsSubsection("Affichage des fichiers") {
                            settingsToggle(
                                "Afficher le poids des fichiers",
                                detail: "La taille apparaît sous chaque fichier.",
                                icon: "scalemass",
                                tint: .indigo,
                                isOn: $showFileSizes
                            )
                            settingsChoice(
                                "Cartes par ligne",
                                icon: "square.grid.2x2",
                                tint: .blue,
                                selection: $fileGridColumns
                            ) {
                                Text("2 cartes").tag(2)
                                Text("3 cartes").tag(3)
                                Text("4 cartes").tag(4)
                                Text("5 cartes").tag(5)
                                Text("6 cartes").tag(6)
                                Text("7 cartes").tag(7)
                            }
                            settingsToggle(
                                "Recherche toujours visible",
                                detail: "Évite de devoir faire glisser la liste pour l’afficher.",
                                icon: "magnifyingglass",
                                tint: .teal,
                                isOn: $alwaysShowSearch
                            )
                        }

                        settingsSubsection("Tags et dossiers") {
                            settingsChoice(
                                "Colonnes des tags",
                                icon: "tag.fill",
                                tint: .brown,
                                selection: $tagGridColumns
                            ) {
                                Text("2 colonnes").tag(2)
                                Text("3 colonnes").tag(3)
                            }
                            settingsToggle(
                                "Dossiers en premier",
                                detail: "Dans les tags, les dossiers apparaissent avant les fichiers.",
                                icon: "folder.fill",
                                tint: .brown,
                                isOn: $foldersFirstInTags
                            )
                            settingsColorPicker(
                                "Couleur par défaut",
                                detail: "Pour les dossiers sans couleur personnalisée.",
                                icon: "folder.fill",
                                color: defaultFolderColorBinding
                            )
                        }

                        settingsSubsection("Navigation et interactions") {
                            settingsToggle(
                                "Revenir en haut dans les favoris",
                                detail: "Un second appui sur l’onglet replace la liste au début.",
                                icon: "arrow.up.to.line",
                                tint: .orange,
                                isOn: $favoritesReselectScrollToTop
                            )
                            settingsToggle(
                                "Retours haptiques",
                                detail: "Une légère vibration accompagne les changements d’onglet.",
                                icon: "hand.tap.fill",
                                tint: .blue,
                                isOn: $hapticFeedbackEnabled
                            )
                        }
                    }

                    settingsCard(
                        title: "Données et performances",
                        message: "Contrôlez le préchargement, l’espace local et les mesures réseau.",
                        icon: "bolt.fill",
                        tint: .orange
                    ) {
                        settingsSubsection("Préchargement") {
                            settingsToggle(
                                "Précharger les miniatures",
                                icon: "photo.stack",
                                tint: .pink,
                                isOn: $prefetchThumbnails
                            )
                            settingsToggle(
                                "Précharger les vidéos",
                                icon: "play.rectangle.fill",
                                tint: .purple,
                                isOn: $prefetchVideoURLs
                            )
                            settingsToggle(
                                "Seulement en Wi-Fi",
                                detail: "Réduit l’utilisation des données mobiles.",
                                icon: "wifi",
                                tint: .cyan,
                                isOn: $prefetchOnWiFiOnly,
                                isEnabled: prefetchThumbnails || prefetchVideoURLs
                            )
                        }

                        settingsSubsection("Cache des miniatures") {
                            settingsInfo(
                                "Espace utilisé",
                                detail: ByteFormatter.string(fromBytes: cacheSize),
                                icon: "internaldrive.fill",
                                tint: .mint
                            )
                            settingsChoice(
                                "Limite automatique",
                                icon: "gauge.with.dots.needle.50percent",
                                tint: .green,
                                selection: $thumbnailCacheLimitMB
                            ) {
                                Text("250 Mo").tag(250)
                                Text("500 Mo").tag(500)
                                Text("1 Go").tag(1_024)
                                Text("Sans limite").tag(0)
                            }
                            settingsButton(
                                "Vider le cache",
                                icon: "trash",
                                tint: .red,
                                role: .destructive
                            ) {
                                Task {
                                    await ThumbnailProvider.shared.purgeDiskCache()
                                    cacheSize = await ThumbnailProvider.shared.diskCacheSize()
                                }
                            }
                        }

                        settingsSubsection("Diagnostic") {
                            settingsToggle(
                                "Suivi des requêtes réseau",
                                detail: "Consultables dans Profil → Réseau. Désactivé, aucune mesure n’est conservée.",
                                icon: "antenna.radiowaves.left.and.right",
                                tint: .indigo,
                                isOn: $networkPerfEnabled
                            )
                        }
                    }

                    settingsCard(
                        title: "Sécurité et compte",
                        message: "Protégez l’accès à l’app et gérez la session enregistrée sur cet appareil.",
                        icon: "lock.shield.fill",
                        tint: .green
                    ) {
                        settingsSubsection("Verrouillage de l’app") {
                            if isLockCodeEnabled {
                                settingsButton(
                                    "Modifier le code",
                                    icon: "pencil",
                                    tint: .blue
                                ) {
                                    showChangeCode = true
                                }
                                settingsButton(
                                    "Désactiver le code",
                                    icon: "lock.open",
                                    tint: .red,
                                    role: .destructive
                                ) {
                                    showDisableCode = true
                                }
                            } else {
                                settingsButton(
                                    "Activer le code de verrouillage",
                                    detail: "Le code sera demandé à chaque ouverture de l’app.",
                                    icon: "lock.fill",
                                    tint: .green
                                ) {
                                    showActivateCode = true
                                }
                            }
                        }

                        settingsSubsection("Session") {
                            settingsButton(
                                "Changer de token / se déconnecter",
                                detail: "Le token et le drive choisi seront retirés de cet appareil.",
                                icon: "rectangle.portrait.and.arrow.right",
                                tint: .red,
                                role: .destructive
                            ) {
                                showSignOutConfirm = true
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.large)
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

    // MARK: - Groupes

    private func refreshLockState() {
        isLockCodeEnabled = AppLockStore.isConfigured
    }

    private func driveSummary(_ drive: Drive) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                settingIcon("externaldrive.fill", tint: .blue, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Drive actuel")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(drive.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if session.drives.count > 1 {
                    Button("Changer") { showDrivePicker = true }
                        .font(.subheadline.weight(.semibold))
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: Double(drive.usedSize ?? 0), total: Double(max(drive.size ?? 1, 1)))
                    .tint(.blue)
                Text(ByteFormatter.usage(used: drive.usedSize, total: drive.size))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.blue.opacity(0.14), lineWidth: 1)
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        message: String? = nil,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                settingIcon(icon, tint: tint, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    }

    private func settingsSubsection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func settingRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
    }

    private func settingsToggle(
        _ title: String,
        detail: String? = nil,
        icon: String,
        tint: Color,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        settingRow {
            Toggle(isOn: isOn) {
                HStack(spacing: 12) {
                    settingIcon(icon, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.medium))
                        if let detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .tint(.accentColor)
            .disabled(!isEnabled)
        }
    }

    private func settingsChoice<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        selection: Binding<Int>,
        @ViewBuilder options: () -> Content
    ) -> some View {
        settingRow {
            HStack(spacing: 12) {
                settingIcon(icon, tint: tint)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Picker(title, selection: selection) {
                    options()
                }
                    .labelsHidden()
                    .pickerStyle(.menu)
            }
        }
    }

    private func settingsColorPicker(
        _ title: String,
        detail: String,
        icon: String,
        color: Binding<Color>
    ) -> some View {
        settingRow {
            HStack(spacing: 12) {
                settingIcon(icon, tint: color.wrappedValue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ColorPicker(title, selection: color, supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private func settingsInfo(
        _ title: String,
        detail: String,
        icon: String,
        tint: Color
    ) -> some View {
        settingRow {
            HStack(spacing: 12) {
                settingIcon(icon, tint: tint)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsButton(
        _ title: String,
        detail: String? = nil,
        icon: String,
        tint: Color,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        settingRow {
            Button(role: role, action: action) {
                HStack(spacing: 12) {
                    settingIcon(icon, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(role == nil ? Color.primary : Color.red)
                        if let detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var defaultFolderColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: defaultFolderColor) ?? FileKind.folder.tint },
            set: { defaultFolderColor = $0.toHex() ?? "#4285F5" }
        )
    }

    private func settingIcon(_ name: String, tint: Color, size: CGFloat = 34) -> some View {
        Image(systemName: name)
            .font(.system(size: size == 34 ? 15 : 20, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
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
