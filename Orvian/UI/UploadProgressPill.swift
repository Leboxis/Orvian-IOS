import SwiftUI

/// Bulle flottante compacte située au-dessus de la barre de navigation et centrée,
/// indiquant l'avancée globale des uploads.
struct UploadProgressPill: View {
    let manager: UploadManager
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 8) {
                if manager.activeTasksCount > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.accentColor)

                    Text(titleText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)

                    Text("\(Int(manager.overallProgress * 100))%")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                } else if manager.hasFailures {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)

                    Text("Erreur de transfert")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.green)

                    Text("Upload terminé")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                }

                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Suivi de l'upload")
    }

    private var titleText: String {
        let count = manager.activeTasksCount
        if count == 1 {
            return "1 upload en cours"
        } else {
            return "\(count) uploads en cours"
        }
    }
}
