import SwiftUI

/// Bulle flottante compacte située au-dessus de la barre de navigation et centrée,
/// indiquant l'avancée globale des uploads (débit et temps restant inclus).
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

                    VStack(alignment: .leading, spacing: 1) {
                        Text(titleText)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                        if !subtitleText.isEmpty {
                            Text(subtitleText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("\(Int(manager.overallProgress * 100))%")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                } else if manager.pausedTasksCount > 0 {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(pausedTitleText)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Toucher pour reprendre")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Suivi de l'upload")
        .accessibilityValue(accessibilityValue)
    }

    private var titleText: String {
        let count = manager.activeTasksCount
        if count == 1 {
            return "1 upload en cours"
        } else {
            return "\(count) uploads en cours"
        }
    }

    private var pausedTitleText: String {
        let count = manager.pausedTasksCount
        if count == 1 {
            return "1 upload en pause"
        } else {
            return "\(count) uploads en pause"
        }
    }

    /// « 4,2 Mo/s • reste 0:42 » (chaque morceau n'apparaît que s'il est connu).
    private var subtitleText: String {
        var parts: [String] = []
        if !manager.overallSpeedText.isEmpty {
            parts.append(manager.overallSpeedText)
        }
        if !manager.overallETAText.isEmpty {
            parts.append("reste \(manager.overallETAText)")
        }
        return parts.joined(separator: " • ")
    }

    private var accessibilityValue: String {
        if manager.activeTasksCount > 0 {
            var value = "\(Int(manager.overallProgress * 100)) pour cent"
            if !subtitleText.isEmpty {
                value += ", \(subtitleText)"
            }
            return value
        }
        return titleText
    }
}
