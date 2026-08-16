import SwiftUI

/// Onglet « Plus » : réglages, stockage, cache, fonctions à venir.
struct MoreView: View {
    let session: SessionStore

    @State private var cacheSize: Int = 0
    @State private var showDrivePicker = false
    @State private var showSignOutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                driveSection
                cacheSection
                upcomingSection
                aboutSection
            }
            .navigationTitle("Plus")
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
                    Gauge(value: Double(drive.usedSize ?? 0), in: 0...Double(max(drive.size ?? 1, 1)))
                        .gaugeStyle(.accessoryLinearCapacity)
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

    private var cacheSection: some View {
        Section {
            HStack {
                Label("Miniatures", systemImage: "photo.stack")
                Spacer()
                Text(ByteFormatter.string(fromBytes: cacheSize))
                    .foregroundStyle(.secondary)
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
            Text("Les miniatures sont re-téléchargées à la demande après la purge.")
        }
    }

    private var upcomingSection: some View {
        Section {
            upcomingRow("Recherche", symbol: "magnifyingglass")
            upcomingRow("Corbeille", symbol: "trash")
            upcomingRow("Upload", symbol: "square.and.arrow.up")
            upcomingRow("Liens de partage", symbol: "link")
            upcomingRow("Actions sur fichiers", symbol: "ellipsis.circle")
        } header: {
            Text("Bientôt disponible")
        }
    }

    private func upcomingRow(_ title: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundStyle(.primary)
            Spacer()
            Text("à venir")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                    .foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://developer.infomaniak.com")!) {
                Label("API kDrive Infomaniak", systemImage: "network")
            }
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Changer de token / se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("À propos")
        } footer: {
            Text("Orvian est un client non officiel pour kDrive (Infomaniak).")
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
