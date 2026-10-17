import SwiftUI
import UIKit

/// Pastille de titre copiable, partagée par la visionneuse d'images et le
/// lecteur vidéo. Le tap copie le nom dans le presse-papiers et affiche
/// brièvement « Copié ». L'état et la tâche de réinitialisation, auparavant
/// recopiés dans chaque vue, vivent ici.
struct MediaTitlePill: View {
    let name: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = name
            copied = true
            scheduleReset()
        } label: {
            Group {
                if copied {
                    Label("Copié", systemImage: "doc.on.doc")
                        .font(.footnote.weight(.medium))
                } else {
                    Text(name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.75), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Nom copié" : name)
        .accessibilityHint("Copier le nom du fichier")
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
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.75), in: Circle())
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
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.75), in: Circle())
        }
        .accessibilityLabel("Appliquer un tag")
    }
}
