import SwiftUI

/// Onglet « Réglages » : drive et stockage local.
struct SettingsView: View {
    let session: SessionStore

    @State private var cacheSize: Int = 0
    @State private var showDrivePicker = false

    var body: some View {
        NavigationStack {
            List {
                driveSection
                cacheSection
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showDrivePicker) {
            DrivePickerSheet(session: session)
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
