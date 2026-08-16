import SwiftUI

/// Point d'entrée : setup → session prête → onglets.
struct RootView: View {
    let session: SessionStore

    var body: some View {
        switch session.phase {
        case .signedOut:
            TokenSetupView(session: session)
        case .bootstrapping:
            BootSplash()
        case let .error(message):
            BootstrapError(message: message) {
                Task { await session.bootstrap() }
            } onSignOut: {
                session.signOut()
            }
        case .signedIn:
            if let drive = session.selectedDrive {
                MainTabView(drive: drive, session: session)
                    .id(drive.id) // changer de drive reconstruit les onglets
            } else {
                BootSplash()
            }
        }
    }
}

private struct BootSplash: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                AppMark()
                    .font(.system(size: 56, weight: .bold))
                ProgressView()
            }
        }
    }
}

private struct BootstrapError: View {
    let message: String
    let onRetry: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Connexion impossible", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            HStack {
                Button("Réessayer", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button("Changer de token", action: onSignOut)
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Monogramme de l'app (placeholder en attendant une icône dédiée).
struct AppMark: View {
    var body: some View {
        Text("O")
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.56, green: 0.38, blue: 0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}
