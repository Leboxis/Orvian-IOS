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
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true
    @AppStorage("prefetchThumbnails") private var prefetchThumbnails = true
    @AppStorage("prefetchVideoURLs") private var prefetchVideoURLs = true
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = false
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB = 250
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true
    @AppStorage("reduceMotion") private var reduceMotion = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let drive = session.selectedDrive {
                        driveSummary(drive)
                    }

                    settingsCard(
                        title: "Affichage",
                        message: "Personnalisez les informations visibles dans vos fichiers."
                    ) {
                        settingsToggle(
                            "Afficher le poids des fichiers",
                            detail: "La taille apparaît sous chaque fichier.",
                            icon: "scalemass",
                            tint: .indigo,
                            isOn: $showFileSizes
                        )
                        settingsDivider
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
                    }

                    settingsCard(
                        title: "Navigation",
                        message: "Choisissez le comportement de l’onglet Favoris."
                    ) {
                        settingsToggle(
                            "Revenir en haut dans les favoris",
                            detail: "Un second appui sur l’onglet replace la liste au début.",
                            icon: "arrow.up.to.line",
                            tint: .orange,
                            isOn: $favoritesReselectScrollToTop
                        )
                    }

                    settingsCard(
                        title: "Médias",
                        message: "Le préchargement rend les miniatures et vidéos plus immédiates."
                    ) {
                        settingsToggle(
                            "Précharger les miniatures",
                            icon: "photo.stack",
                            tint: .pink,
                            isOn: $prefetchThumbnails
                        )
                        settingsDivider
                        settingsToggle(
                            "Précharger les vidéos",
                            icon: "play.rectangle.fill",
                            tint: .purple,
                            isOn: $prefetchVideoURLs
                        )
                        settingsDivider
                        settingsToggle(
                            "Précharger seulement en Wi-Fi",
                            detail: "Réduit l’utilisation des données mobiles.",
                            icon: "wifi",
                            tint: .cyan,
                            isOn: $prefetchOnWiFiOnly,
                            isEnabled: prefetchThumbnails || prefetchVideoURLs
                        )
                    }

                    settingsCard(
                        title: "Stockage local",
                        message: "Les miniatures sont conservées temporairement pour accélérer l’affichage."
                    ) {
                        HStack(spacing: 12) {
                            settingIcon("internaldrive.fill", tint: .mint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Miniatures enregistrées")
                                    .font(.body.weight(.medium))
                                Text(ByteFormatter.string(fromBytes: cacheSize))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)

                        settingsDivider
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
                        settingsDivider
                        Button {
                            Task {
                                await ThumbnailProvider.shared.purgeDiskCache()
                                cacheSize = await ThumbnailProvider.shared.diskCacheSize()
                            }
                        } label: {
                            Label("Vider le cache", systemImage: "trash")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }

                    settingsCard(title: "Confort") {
                        settingsToggle(
                            "Retours haptiques",
                            detail: "Une légère vibration accompagne les changements d’onglet.",
                            icon: "hand.tap.fill",
                            tint: .blue,
                            isOn: $hapticFeedbackEnabled
                        )
                        settingsDivider
                        settingsToggle(
                            "Réduire les animations",
                            detail: "Privilégie des transitions plus sobres.",
                            icon: "wind",
                            tint: .gray,
                            isOn: $reduceMotion
                        )
                    }

                    accountSection
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
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
        .padding(.vertical, 2)
    }

    private func settingsChoice<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        selection: Binding<Int>,
        @ViewBuilder options: () -> Content
    ) -> some View {
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
        .padding(.vertical, 2)
    }

    private func settingIcon(_ name: String, tint: Color, size: CGFloat = 34) -> some View {
        Image(systemName: name)
            .font(.system(size: size == 34 ? 15 : 20, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 46)
    }

    private var accountSection: some View {
        settingsCard(
            title: "Compte",
            message: "Le token et le drive choisi sont enregistrés uniquement sur cet appareil."
        ) {
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Changer de token / se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
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
