import SwiftUI
import UIKit

/// Points affichant la progression de la saisie d'un code, centrés sous le titre.
struct CodeDots: View {
    let filledCount: Int
    let length: Int
    var isError = false

    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { index in
                let isFilled = filledCount > index
                Circle()
                    .fill(dotColor.opacity(isFilled ? 0.85 : 0.08))
                    .overlay {
                        if !isFilled {
                            Circle().strokeBorder(dotColor.opacity(0.18), lineWidth: 1.5)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .scaleEffect(filledCount == index + 1 ? 1.12 : 1)
                    .animation(.snappy(duration: 0.18), value: filledCount)
            }
        }
    }

    private var dotColor: Color { isError ? .red : .primary }
}

/// Pavé numérique 3×4 (chiffres + effacement) partagé par l'écran de
/// verrouillage et les feuilles de configuration du code.
struct CodeKeypad: View {
    var onDigit: (String) -> Void
    var onDelete: () -> Void

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "delete"],
    ]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 76, height: 64)
        } else if key == "delete" {
            Button(action: onDelete) {
                Image(systemName: "delete.left")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 76, height: 64)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(KeypadButtonStyle())
            .accessibilityLabel("Supprimer le dernier chiffre")
        } else {
            Button { onDigit(key) } label: {
                Text(key)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 76, height: 64)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(KeypadButtonStyle())
            .accessibilityLabel("Chiffre \(key)")
        }
    }
}

private struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Oscillation horizontale signalant une saisie erronée. Anime
/// `animatableData` de n vers n+1 pour produire trois allers-retours.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 9
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travel * sin(animatableData * .pi * shakesPerUnit * 2),
                y: 0
            )
        )
    }
}

/// Retours haptiques du pavé, respectant le réglage « Retours haptiques ».
enum AppLockHaptics {
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
    }

    static func keyPress() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func failure() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
