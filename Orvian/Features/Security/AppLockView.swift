import SwiftUI

/// Écran de verrouillage affiché au lancement lorsqu'un code est configuré :
/// monogramme, zone de saisie centrée et pavé numérique dans le style de l'app.
/// Tant que le code n'est pas validé, le contenu de l'app n'est pas construit.
struct AppLockView: View {
    var onUnlock: () -> Void

    @State private var code = ""
    @State private var shakeTrigger = 0
    @State private var showWrong = false

    private let codeLength = 4

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 24)

                AppMark()
                    .font(.system(size: 40, weight: .bold))

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

                if showWrong {
                    Label("Code incorrect", systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()
                Spacer(minLength: 0)

                CodeKeypad(onDigit: handleDigit, onDelete: handleDelete)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
    }

    private func handleDigit(_ digit: String) {
        guard code.count < codeLength else { return }
        AppLockHaptics.keyPress()
        code += digit
        guard code.count == codeLength else { return }

        if AppLockStore.verify(code) {
            AppLockHaptics.success()
            onUnlock()
        } else {
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
        guard !code.isEmpty else { return }
        code.removeLast()
    }
}
