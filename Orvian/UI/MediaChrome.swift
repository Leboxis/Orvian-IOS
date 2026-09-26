import SwiftUI
import UIKit

/// Pastille de titre copiable, partagée par la visionneuse d'images et le
/// lecteur vidéo. Le tap copie le nom dans le presse-papiers et affiche
/// brièvement « Copié ». L'état et la tâche de réinitialisation, auparavant
/// recopiés dans chaque vue, vivent ici.
struct MediaTitlePill: View {
    let name: String
    /// Largeur réservée de part et d'autre du titre, en fraction de l'écran
    /// (0,2 = 20 % de chaque côté, comme les barres historiques).
    let sideInsetFraction: CGFloat = 0.2

    @State private var containerWidth: CGFloat = 0
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        // La réserve de part et d'autre du titre vient de la largeur **offerte**
        // par l'écran, relevée sur une sonde transparente dédiée. Sonder la
        // pastille elle-même liait sa largeur au padding calculé sur cette
        // largeur : la mesure ne pouvait se stabiliser qu'après une seconde
        // passe, d'où le titre qui se replace à l'apparition et à chaque
        // rotation. `Color.clear` étant souple aussi en hauteur, la sonde est
        // bridée à zéro : sans cela la pastille prendrait toute la hauteur
        // disponible.
        ZStack {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }

            Group {
                if copied {
                    Label("Copié", systemImage: "doc.on.doc")
                        .font(.footnote.weight(.medium))
                } else {
                    Text(name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.black.opacity(0.25), in: Capsule())
            .contentShape(Capsule())
            .padding(.horizontal, containerWidth * sideInsetFraction)
            .onTapGesture {
                UIPasteboard.general.string = name
                copied = true
                scheduleReset()
            }
        }
        .onChange(of: name) { _, _ in
            // Changement de média : l'accusé « Copié » ne doit pas suivre.
            resetTask?.cancel()
            copied = false
        }
        .onDisappear {
            resetTask?.cancel()
        }
    }

    private func scheduleReset() {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.animation(.easeInOut(duration: 0.2))) {
                copied = false
            }
        }
    }
}

/// Étoile favori, apparence et mise à jour optimiste identiques dans la
/// visionneuse d'images et le lecteur vidéo.
struct MediaFavoriteButton: View {
    let isFavorite: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFavorite ? .yellow : .white)
                .frame(width: 30, height: 30)
        }
        .disabled(isDisabled)
        .accessibilityLabel(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
    }
}

/// Bouton d'ouverture de l'éditeur de tags, apparence identique dans la
/// visionneuse d'images et le lecteur vidéo.
struct MediaTagButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "tag")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel("Appliquer un tag")
    }
}
