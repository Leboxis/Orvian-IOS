import SwiftUI

/// Onglet « Profil » : compte Infomaniak, drive utilisé, déconnexion.
struct ProfileView: View {
    let session: SessionStore

    @State private var accountName: String?
    @State private var showSignOutConfirm = false

    private let service = KDriveService()

    var body: some View {
        NavigationStack {
            List {
                headerSection
                driveSection
                aboutSection
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.large)
        }
        .confirmationDialog("Se déconnecter ?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
                session.signOut()
            }
        } message: {
            Text("Le token et le drive sélectionné seront effacés de cet appareil.")
        }
        .task {
            await loadAccountName()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.56, green: 0.38, blue: 0.94)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String((accountName ?? "O").prefix(1)).uppercased())
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76)

                VStack(spacing: 3) {
                    Text(accountName ?? "Compte Infomaniak")
                        .font(.headline)
                    if accountName == nil {
                        Text("Chargement…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private var driveSection: some View {
        Section {
            if let drive = session.selectedDrive {
                HStack {
                    Label(drive.name, systemImage: "externaldrive.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(ByteFormatter.usage(used: drive.usedSize, total: drive.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Changer de token / se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("Drive")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://developer.infomaniak.com")!) {
                Label("API kDrive Infomaniak", systemImage: "network")
            }
        } header: {
            Text("À propos")
        } footer: {
            Text("Orvian est un client non officiel pour kDrive (Infomaniak).")
        }
    }

    // MARK: - Chargement

    private func loadAccountName() async {
        guard let accounts = try? await service.accounts(),
              let id = session.accountId else { return }
        accountName = accounts.first(where: { $0.id == id })?.name
    }
}
