import SwiftUI

/// Point d'entrée : verrouillage (si un code est configuré) → setup →
/// session prête → onglets.
struct RootView: View {
    let session: SessionStore

    @Environment(\.scenePhase) private var scenePhase

    /// Déverrouillage en mémoire : repasse par le code à chaque ouverture.
    @State private var isUnlocked = false

    /// Vrai dès que l'app a quitté le premier plan : la biométrie est alors
    /// proposée automatiquement au retour, jamais au premier lancement.
    @State private var hasGoneBackground = false

    private var isLockRequired: Bool {
        AppLockStore.isConfigured && !isUnlocked
    }

    var body: some View {
        Group {
            if isLockRequired {
                // Le contenu de l'app n'est pas construit avant le code.
                AppLockView(autoPromptBiometrics: hasGoneBackground) {
                    withAnimation(.snappy(duration: 0.25)) {
                        isUnlocked = true
                    }
                }
            } else {
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
        .onReceive(NotificationCenter.default.publisher(for: .apiUnauthorized)) { notification in
            session.handleUnauthorized(credentialFingerprint: notification.object as? String)
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-verrouille dès que l'app quitte le premier plan : au retour
            // (rappel puis reprise), le code ou Face ID est redemandé.
            guard AppLockStore.isConfigured else { return }
            if phase == .background {
                hasGoneBackground = true
                isUnlocked = false
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

/// Monogramme Constellation affiché pendant l'onboarding et le verrouillage.
struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.47, blue: 0.95), Color(red: 0.53, green: 0.35, blue: 0.91)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(.white.opacity(0.28), lineWidth: 1)
                .frame(width: 58, height: 58)

            Path { path in
                path.move(to: CGPoint(x: 27, y: 28))
                path.addLine(to: CGPoint(x: 60, y: 33))
                path.addLine(to: CGPoint(x: 51, y: 61))
                path.closeSubpath()
            }
            .stroke(.white.opacity(0.55), lineWidth: 1.6)

            Circle()
                .fill(.white.opacity(0.87))
                .frame(width: 34, height: 34)
            Circle()
                .stroke(Color(red: 0.42, green: 0.38, blue: 0.87), lineWidth: 4.5)
                .frame(width: 19, height: 19)

            Circle().fill(.white).frame(width: 9, height: 9).offset(x: -17, y: -16)
            Circle().fill(.white).frame(width: 9, height: 9).offset(x: 16, y: -11)
            Circle().fill(.white).frame(width: 9, height: 9).offset(x: 7, y: 17)
        }
        .frame(width: 88, height: 88)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}
