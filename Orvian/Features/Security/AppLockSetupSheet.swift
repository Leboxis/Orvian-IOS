import SwiftUI

/// Configuration du code de verrouillage depuis les réglages :
/// activation (saisie + confirmation), modification (code actuel puis
/// nouveau code + confirmation) ou désactivation (code actuel requis).
struct AppLockSetupSheet: View {
    enum Flow {
        case activate
        case change
        case disable
    }

    private enum Stage {
        case verifyCurrent
        case enterNew
        case confirmNew
    }

    let flow: Flow

    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage
    @State private var code = ""
    @State private var firstEntry = ""
    @State private var shakeTrigger = 0
    @State private var errorMessage: String?

    private let codeLength = 4

    init(flow: Flow) {
        self.flow = flow
        _stage = State(initialValue: flow == .activate ? .enterNew : .verifyCurrent)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    AppMark()
                        .font(.system(size: 34, weight: .bold))

                    VStack(spacing: 6) {
                        Text(stageTitle)
                            .font(.title3.bold())
                        Text(stageSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    CodeDots(filledCount: code.count, length: codeLength, isError: errorMessage != nil)
                        .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
                        .animation(.easeInOut(duration: 0.45), value: shakeTrigger)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                CodeKeypad(onDigit: handleDigit, onDelete: handleDelete)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .interactiveDismissDisabled(!code.isEmpty)
    }

    private var navigationTitle: String {
        switch flow {
        case .activate: return "Nouveau code"
        case .change: return "Modifier le code"
        case .disable: return "Désactiver le code"
        }
    }

    private var stageTitle: String {
        switch stage {
        case .verifyCurrent:
            return flow == .disable ? "Désactiver le verrouillage" : "Code actuel"
        case .enterNew:
            return "Choisissez un code"
        case .confirmNew:
            return "Confirmez le code"
        }
    }

    private var stageSubtitle: String {
        switch stage {
        case .verifyCurrent:
            return flow == .disable
                ? "Saisissez votre code actuel pour désactiver le verrouillage."
                : "Saisissez votre code actuel pour continuer."
        case .enterNew:
            return "Choisissez un code à \(codeLength) chiffres."
        case .confirmNew:
            return "Saisissez à nouveau le même code."
        }
    }

    private func handleDigit(_ digit: String) {
        guard code.count < codeLength else { return }
        AppLockHaptics.keyPress()
        code += digit
        guard code.count == codeLength else { return }
        evaluate()
    }

    private func handleDelete() {
        guard !code.isEmpty else { return }
        code.removeLast()
    }

    private func evaluate() {
        switch stage {
        case .verifyCurrent:
            if AppLockStore.verify(code) {
                if flow == .disable {
                    AppLockStore.clear()
                    AppLockHaptics.success()
                    dismiss()
                } else {
                    stage = .enterNew
                    code = ""
                    errorMessage = nil
                }
            } else {
                fail("Code incorrect.")
            }

        case .enterNew:
            firstEntry = code
            code = ""
            stage = .confirmNew
            errorMessage = nil

        case .confirmNew:
            if code == firstEntry {
                AppLockStore.save(code)
                AppLockHaptics.success()
                dismiss()
            } else {
                fail("Les codes ne correspondent pas.") {
                    stage = .enterNew
                    firstEntry = ""
                }
            }
        }
    }

    private func fail(_ message: String, then cleanup: (() -> Void)? = nil) {
        AppLockHaptics.failure()
        withAnimation(.snappy(duration: 0.2)) { errorMessage = message }
        shakeTrigger += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation(.snappy(duration: 0.2)) { code = "" }
            cleanup?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if errorMessage == message { errorMessage = nil }
        }
    }
}
