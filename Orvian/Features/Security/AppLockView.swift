import SwiftUI
import LocalAuthentication

/// Écran de verrouillage affiché au lancement lorsqu'un code est configuré :
/// monogramme, zone de saisie centrée et pavé numérique dans le style de l'app.
/// Un tap sur le monogramme lance la biométrie (Face ID / Touch ID / Optic ID)
/// sans avoir à saisir le code ; elle est aussi présentée automatiquement au
/// retour d'arrière-plan (`autoPromptBiometrics`), jamais au premier lancement.
/// Tant que le déverrouillage n'a pas eu lieu, le contenu de l'app n'est pas
/// construit.
struct AppLockView: View {
    var autoPromptBiometrics = false
    var onUnlock: () -> Void

    @State private var code = ""
    @State private var shakeTrigger = 0
    @State private var showWrong = false
    @State private var isAuthenticating = false
    @State private var biometricsMessage: String?
    @State private var isCheckingCode = false
    @State private var retryAfter = AppLockStore.retryAfter

    private let codeLength = 4

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 24)

                AppMark()
                    .font(.system(size: 40, weight: .bold))
                    .onTapGesture(perform: authenticateWithBiometrics)
                    .accessibilityLabel(biometricsAvailable ? "Déverrouiller avec \(biometryName)" : "Logo Orvian")
                    .accessibilityHint(biometricsAvailable ? "Lance l'authentification biométrique" : "")

                VStack(spacing: 6) {
                    Text("Orvian verrouillé")
                        .font(.title2.bold())
                    Text("Entrez votre code pour accéder à l'app")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                CodeDots(filledCount: code.count, length: codeLength, isError: showWrong)
                    .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
                    .animation(.easeInOut(duration: 0.45), value: shakeTrigger)

                if retryAfter > 0 {
                    Text("Réessayez dans \(retryAfter) s")
                        .font(.footnote).monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if showWrong || biometricsMessage != nil {
                    Label(biometricsMessage ?? "Code incorrect", systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(showWrong ? .red : .secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()
                Spacer(minLength: 0)

                CodeKeypad(onDigit: handleDigit, onDelete: handleDelete)
                    .disabled(isCheckingCode || isAuthenticating || showWrong || retryAfter > 0)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .task {
            // Face ID est proposé d'office au retour d'arrière-plan,
            // mais pas au premier lancement de l'app.
            if autoPromptBiometrics, biometricsAvailable { authenticateWithBiometrics() }
            while !Task.isCancelled {
                retryAfter = AppLockStore.retryAfter
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    // MARK: - Biométrie

    private var biometricsAvailable: Bool {
        var error: NSError?
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private var biometryName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Face ID"
        }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    /// Authentification biométrique locale : en cas de succès, le code n'est
    /// pas requis. L'échec laisse la saisie du code disponible.
    private func authenticateWithBiometrics() {
        guard !isAuthenticating, !isCheckingCode else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            withAnimation(.snappy(duration: 0.2)) {
                biometricsMessage = "\(biometryName) indisponible sur cet appareil."
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                withAnimation(.snappy(duration: 0.2)) { biometricsMessage = nil }
            }
            return
        }

        isAuthenticating = true
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Déverrouiller Orvian"
        ) { success, _ in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    AppLockStore.resetAttempts()
                    AppLockHaptics.success()
                    onUnlock()
                } else {
                    AppLockHaptics.failure()
                }
            }
        }
    }

    private func handleDigit(_ digit: String) {
        guard !isCheckingCode, !isAuthenticating, !showWrong,
              AppLockStore.retryAfter == 0, code.count < codeLength else { return }
        AppLockHaptics.keyPress()
        code += digit
        guard code.count == codeLength else { return }

        isCheckingCode = true
        let enteredCode = code
        Task {
            defer {
                isCheckingCode = false
                retryAfter = AppLockStore.retryAfter
            }
            do {
                let matches = try await AppLockStore.verify(enteredCode)
                if matches {
                    AppLockHaptics.success()
                    onUnlock()
                    return
                }
                biometricsMessage = nil
            } catch {
                biometricsMessage = error.localizedDescription
            }
            AppLockHaptics.failure()
            withAnimation(.snappy(duration: 0.2)) { showWrong = true }
            shakeTrigger += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                withAnimation(.snappy(duration: 0.2)) {
                    code = ""
                    showWrong = false
                }
            }
        }
    }

    private func handleDelete() {
        guard !isCheckingCode, !showWrong, !code.isEmpty else { return }
        code.removeLast()
    }
}
