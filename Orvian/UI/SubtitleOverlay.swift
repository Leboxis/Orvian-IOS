import SwiftUI

/// Bouton « CC / Traduction » des commandes du lecteur.
struct SubtitleModeMenu: View {
    let mode: SubtitleMode
    let isSubtle: Bool
    let action: (SubtitleMode) -> Void

    var body: some View {
        Menu {
            ForEach(SubtitleMode.allCases) { option in
                Button {
                    action(option)
                } label: {
                    if option == mode {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Image(systemName: mode == .off ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(isSubtle ? 0.8 : 1))
                .frame(width: 44, height: 44)
                .background(.white.opacity(isSubtle ? 0.06 : 0.12), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Sous-titres")
        .accessibilityValue(mode.title)
        .accessibilityHint("Choisit la langue des sous-titres automatiques")
    }
}

/// Sous-titres affichés au-dessus des commandes de lecture.
///
/// Non interactif : les gestes de la vidéo (double-tap ±10 s, bascule du
/// chrome) doivent continuer de fonctionner à travers le texte.
struct SubtitleOverlay: View {
    let cue: SubtitleCue?
    let bottomInset: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let cue {
                Text(cue.text)
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 20 : 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomInset)
                    .transition(.opacity)
                    .accessibilityLabel(cue.isTranslated ? "Sous-titre traduit" : "Sous-titre anglais")
                    .accessibilityValue(cue.text)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: cue)
    }
}
