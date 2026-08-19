import SwiftUI

/// Onglet « Réglages » : drive et stockage local.
struct SettingsView: View {
    let session: SessionStore
    @Binding var path: NavigationPath

    @State private var cacheSize: Int = 0
    @State private var showDrivePicker = false
    @State private var showSignOutConfirm = false
    @AppStorage("fileGridColumns") private var fileGridColumns = 3
    @AppStorage("alwaysShowSearch") private var alwaysShowSearch = false
    @AppStorage("favoritesReselectScrollToTop") private var favoritesReselectScrollToTop = true
    @AppStorage("prefetchThumbnails") private var prefetchThumbnails = true
    @AppStorage("prefetchVideoURLs") private var prefetchVideoURLs = true
    @AppStorage("prefetchOnWiFiOnly") private var prefetchOnWiFiOnly = false
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB = 250
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true
    @AppStorage("reduceMotion") private var reduceMotion = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                driveSection
                displaySection
                navigationSection
                mediaSection
                cacheSection
                comfortSection
                sessionSection
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 90)
            }
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
            Task { await MediaURLCache.shared.cancelPrefetch() }
        }
        .onChange(of: prefetchOnWiFiOnly) { _, enabled in
            guard enabled else { return }
            Task {
                await ThumbnailProvider.shared.cancelPrefetch()
                await MediaURLCache.shared.cancelPrefetch()
            }
        }
        .onChange(of: thumbnailCacheLimitMB) { _, _ in
            Task {
                await ThumbnailProvider.shared.enforceDiskLimit()
                cacheSize = await ThumbnailProvider.shared.diskCacheSize()
            }
        }
    }

    // MARK: - Sections

    private var driveSection: some View {
        Section {
            if let drive = session.selectedDrive {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.blue)
                        Text(drive.name).font(.headline)
                        Spacer()
                        if session.drives.count > 1 {
                            Button("Changer") { showDrivePicker = true }
                                .font(.footnote)
                        }
                    }
                    ProgressView(value: Double(drive.usedSize ?? 0), total: Double(max(drive.size ?? 1, 1)))
                        .tint(.blue)
                        .accessibilityLabel("Stockage du drive")
                    Text(ByteFormatter.usage(used: drive.usedSize, total: drive.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Drive")
        }
    }

    private var displaySection: some View {
        Section("Affichage") {
            Picker("Cartes par ligne", selection: $fileGridColumns) {
                Text("2 cartes").tag(2)
                Text("3 cartes").tag(3)
                Text("4 cartes").tag(4)
            }

            Toggle("Recherche toujours visible", isOn: $alwaysShowSearch)
        } footer: {
            Text("La recherche reste affichée dans les dossiers de l'Accueil au lieu d'apparaître après un défilement vers le haut.")
        }
    }

    private var navigationSection: some View {
        Section("Navigation") {
            Toggle("Favoris : retour en haut au second appui", isOn: $favoritesReselectScrollToTop)
        } footer: {
            Text("Un nouvel appui sur l'onglet Favoris revient à la racine ; activez cette option pour remonter aussi la liste en haut.")
        }
    }

    private var mediaSection: some View {
        Section("Médias") {
            Toggle("Précharger les miniatures", isOn: $prefetchThumbnails)
            Toggle("Précharger les vidéos", isOn: $prefetchVideoURLs)
            Toggle("Précharger seulement en Wi-Fi", isOn: $prefetchOnWiFiOnly)
                .disabled(!prefetchThumbnails && !prefetchVideoURLs)
        } footer: {
            Text("Le préchargement prépare les éléments juste après la zone visible. Le désactiver économise les données, mais l'affichage ou le démarrage d'une vidéo peut être moins immédiat.")
        }
    }

    private var cacheSection: some View {
        Section {
            HStack {
                Label("Miniatures", systemImage: "photo.stack")
                Spacer()
                Text(ByteFormatter.string(fromBytes: cacheSize))
                    .foregroundStyle(.secondary)
            }
            Picker("Limite automatique", selection: $thumbnailCacheLimitMB) {
                Text("250 Mo").tag(250)
                Text("500 Mo").tag(500)
                Text("1 Go").tag(1_024)
                Text("Sans limite").tag(0)
            }
            Button(role: .destructive) {
                Task {
                    await ThumbnailProvider.shared.purgeDiskCache()
                    cacheSize = await ThumbnailProvider.shared.diskCacheSize()
                }
            } label: {
                Label("Vider le cache", systemImage: "trash")
            }
        } header: {
            Text("Stockage local")
        } footer: {
            Text("Au-delà de la limite choisie, les miniatures les plus anciennes sont supprimées automatiquement. Elles sont re-téléchargées à la demande après une purge.")
        }
    }

    private var comfortSection: some View {
        Section("Confort") {
            Toggle("Retours haptiques", isOn: $hapticFeedbackEnabled)
            Toggle("Réduire les animations", isOn: $reduceMotion)
        } footer: {
            Text("Les retours haptiques accompagnent les changements d'onglet. La réduction des animations privilégie des transitions plus sobres.")
        }
    }

    private var sessionSection: some View {
        Section {
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Changer de token / se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("Compte")
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
