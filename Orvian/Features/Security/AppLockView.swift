import SwiftUI
import LocalAuthentication

/// Écran de verrouillage affiché au lancement lorsqu'un code est configuré :
/// monogramme, zone de saisie centrée et pavé numérique dans le style de l'app.
/// Un tap sur le monogramme lance la biométrie (Face ID / Touch ID / Optic ID)
/// sans avoir à saisir le code ; elle est aussi présentée automatiquement au
/// retour d'arrière-plan (`autoPromptBiometrics`), jamais au premier lancement.
/// Au premier lancement, le contenu attend le déverrouillage ; aux retours
/// suivants, il reste conservé derrière la fenêtre de protection.
struct AppLockView: View {
    var autoPromptBiometrics = false
    /// Succès biométrique uniquement (le code utilise `onUnlock`). Séparé car
    /// Face ID prend 1 à 3 s : un jeton capturé au lancement de l'invite peut
    /// être périmé à son retour. Par défaut, repli sur `onUnlock`.
    var onBiometricUnlock: (() -> Void)?
    var onUnlock: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var shakeTrigger = 0
    @State private var showWrong = false
    @State private var isAuthenticating = false
    @State private var didAutoPrompt = false
    @State private var authenticationGeneration = 0
    @State private var authenticationContext: LAContext?
    @State private var biometricsMessage: String?
    @State private var isCheckingCode = false
    @State private var retryAfter = AppLockStore.retryAfter

    private let codeLength = 4

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    if proxy.size.width > proxy.size.height {
                        landscapeContent
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    } else {
                        portraitContent
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                cancelBiometrics()
                didAutoPrompt = false
            } else if phase == .active {
                promptBiometricsIfNeeded()
            }
        }
        .onDisappear { cancelBiometrics() }
        .task {
            // Face ID est proposé d'office au retour d'arrière-plan,
            // mais pas au premier lancement de l'app.
            promptBiometricsIfNeeded()
            while !Task.isCancelled {
                retryAfter = AppLockStore.retryAfter
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// En portrait, conserve la composition historique. Le `ScrollView`
    /// parent ne bouge que si une petite hauteur ou Dynamic Type l'exige.
    private var portraitContent: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)
            lockIdentity
            Spacer(minLength: 16)
            keypad
                .padding(.bottom, 24)
        }
    }

    /// En paysage, place le pavé à côté de l'identité plutôt que sous
    /// celle-ci. Les quatre rangées restent ainsi visibles sur une faible
    /// hauteur ; le défilement reste un filet de sécurité pour le texte agrandi.
    private var landscapeContent: some View {
        HStack(spacing: 24) {
            lockIdentity
                .frame(maxWidth: .infinity)
            keypad
        }
    }

    private var lockIdentity: some View {
        VStack(spacing: 20) {
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
            .multilineTextAlignment(.center)

            CodeDots(filledCount: code.count, length: codeLength, isError: showWrong)
                .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
                .animation(.easeInOut(duration: 0.45), value: shakeTrigger)

            statusMessage
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if retryAfter > 0 {
            Text("Réessayez dans \(retryAfter) s")
                .font(.footnote).monospacedDigit()
                .foregroundStyle(.secondary)
        }

        if showWrong || biometricsMessage != nil {
            Label(biometricsMessage ?? "Code incorrect", systemImage: "xmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(showWrong ? .red : .secondary)
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var keypad: some View {
        CodeKeypad(onDigit: handleDigit, onDelete: handleDelete)
            .disabled(isCheckingCode || isAuthenticating || showWrong || retryAfter > 0)
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

    private func promptBiometricsIfNeeded() {
        guard autoPromptBiometrics, !didAutoPrompt, scenePhase == .active, biometricsAvailable else { return }
        didAutoPrompt = true
        authenticateWithBiometrics()
    }

    private func cancelBiometrics() {
        authenticationGeneration &+= 1
        authenticationContext?.invalidate()
        authenticationContext = nil
        isAuthenticating = false
    }

    /// Authentification biométrique locale : en cas de succès, le code n'est
    /// pas requis. L'échec laisse la saisie du code disponible.
    private func authenticateWithBiometrics() {
        guard scenePhase == .active, !isAuthenticating, !isCheckingCode else { return }
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
        authenticationContext = context
        let generation = authenticationGeneration
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Déverrouiller Orvian"
        ) { success, error in
            DispatchQueue.main.async {
                guard generation == authenticationGeneration else { return }
                authenticationContext = nil
                isAuthenticating = false
                if success {
                    AppLockStore.resetAttempts()
                    AppLockHaptics.success()
                    // TODO diagnostic temporaire : si ce message reste affiché
                    // sans ouvrir l'app, le succès arrive bien mais le
                    // déverrouillage est refusé ; s'il n'apparaît jamais, le
                    // retour Face ID ne parvient pas jusqu'ici.
                    biometricsMessage = "Face ID OK, ouverture…"
                    (onBiometricUnlock ?? onUnlock)()
                } else {
                    AppLockHaptics.failure()
                    // Un échec biométrique était silencieux : l'utilisateur
                    // voyait Face ID réussir son animation sans comprendre
                    // pourquoi l'app restait verrouillée (verrouillage Face ID
                    // après trop d'essais, annulation…). On l'affiche.
                    withAnimation(.snappy(duration: 0.2)) {
                        biometricsMessage = (error as? LAError)?.localizedDescription
                            ?? error?.localizedDescription
                            ?? "Échec de Face ID : utilisez votre code."
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                        withAnimation(.snappy(duration: 0.2)) { biometricsMessage = nil }
                    }
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
