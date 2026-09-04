import SwiftUI

/// Interface détaillée affichant la liste et l'état de chaque upload, avec
/// débit, temps restant et contrôles par tâche (pause/reprise/annulation).
struct UploadProgressSheet: View {
    @Environment(\.dismiss) private var dismiss
    let manager: UploadManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(summaryTitle)
                                .font(.headline)
                            Spacer()
                            if manager.activeTasksCount > 0 {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        ProgressView(value: manager.overallProgress)
                            .tint(Color.accentColor)

                        HStack {
                            Text("\(manager.completedTasksCount) / \(manager.tasks.count) terminé\(manager.completedTasksCount > 1 ? "s" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !globalStatsText.isEmpty {
                                Text(globalStatsText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(Int(manager.overallProgress * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if manager.tasks.isEmpty {
                        Text("Aucun transfert en cours")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.tasks) { task in
                            uploadRow(task)
                        }
                    }
                } header: {
                    batchActionsHeader
                }
            }
            .navigationTitle("Transferts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if manager.activeTasksCount == 0 && manager.pausedTasksCount == 0 && !manager.tasks.isEmpty {
                        Button("Effacer") {
                            withAnimation {
                                manager.clearCompleted()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var summaryTitle: String {
        if manager.activeTasksCount > 0 {
            return "\(manager.activeTasksCount) transfert\(manager.activeTasksCount > 1 ? "s" : "") en cours"
        } else if manager.pausedTasksCount > 0 {
            return "Transferts en pause"
        } else if manager.hasFailures {
            return "Transferts terminés avec erreur"
        } else {
            return "Tous les transferts sont terminés"
        }
    }

    /// « 4,2 Mo/s • reste 0:42 » pour l'ensemble des envois actifs.
    private var globalStatsText: String {
        var parts: [String] = []
        if !manager.overallSpeedText.isEmpty {
            parts.append(manager.overallSpeedText)
        }
        if !manager.overallETAText.isEmpty {
            parts.append("reste \(manager.overallETAText)")
        }
        return parts.joined(separator: " • ")
    }

    /// Actions de lot : tout suspendre / reprendre / annuler.
    @ViewBuilder
    private var batchActionsHeader: some View {
        let hasActive = manager.tasks.contains { $0.isActive }
        let hasPaused = manager.tasks.contains { $0.isPaused }
        let hasCancellable = manager.tasks.contains { $0.canCancel }
        if hasActive || hasPaused {
            HStack(spacing: 16) {
                Text("Fichiers")
                Spacer()
                if hasActive {
                    Button("Tout suspendre") { manager.pauseAll() }
                        .font(.caption.weight(.semibold))
                }
                if hasPaused {
                    Button("Tout reprendre") { manager.resumeAll() }
                        .font(.caption.weight(.semibold))
                }
                if hasCancellable {
                    Button("Tout annuler", role: .destructive) { manager.cancelAllActive() }
                        .font(.caption.weight(.semibold))
                }
            }
        } else {
            Text("Fichiers")
        }
    }

    @ViewBuilder
    private func uploadRow(_ task: UploadTaskItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.isPaused ? "pause.circle.fill" : "doc.fill")
                .font(.system(size: 20))
                .foregroundStyle(task.isPaused ? .orange : Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(sizeLine(for: task))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if case let .inProgress(progress) = task.status, !task.isPaused {
                    ProgressView(value: progress)
                        .tint(Color.accentColor)
                }

                if !detailLine(for: task).isEmpty {
                    Text(detailLine(for: task))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if case let .failed(message) = task.status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if task.isPaused {
                    Text("En pause — le fichier est conservé pour la reprise.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            rowControls(for: task)
        }
        .padding(.vertical, 2)
    }

    /// « 12,4 Mo / 48 Mo » pendant l'envoi, sinon taille totale ou état.
    private func sizeLine(for task: UploadTaskItem) -> String {
        switch task.status {
        case .queued:
            return task.totalBytes > 0 ? "\(ByteFormatter.format(task.totalBytes)) • en attente" : "En attente"
        case .inProgress:
            if task.totalBytes > 0, task.uploadedBytes > 0 {
                return "\(ByteFormatter.string(fromBytes: task.uploadedBytes)) / \(ByteFormatter.string(fromBytes: task.totalBytes))"
            }
            return ByteFormatter.format(task.totalBytes)
        case .completed:
            return ByteFormatter.format(task.totalBytes)
        case .failed:
            return ByteFormatter.format(task.totalBytes)
        }
    }

    /// « 4,2 Mo/s • reste 0:42 » ou « 38 % » selon ce qui est connu.
    private func detailLine(for task: UploadTaskItem) -> String {
        guard case let .inProgress(progress) = task.status, !task.isPaused else { return "" }
        var parts: [String] = []
        let speed = UploadManager.speedText(task.speedBytesPerSec)
        if !speed.isEmpty {
            parts.append(speed)
        }
        let eta = UploadManager.etaText(task.etaSeconds)
        if !eta.isEmpty {
            parts.append("reste \(eta)")
        }
        if parts.isEmpty {
            // Débit pas encore mesurable (premiers ticks) : le % suffit.
            parts.append("\(Int(progress * 100)) %")
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func rowControls(for task: UploadTaskItem) -> some View {
        HStack(spacing: 14) {
            if task.canPause {
                Button {
                    manager.pauseTask(task.id)
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Suspendre « \(task.fileName) »")
            }
            if task.canResume {
                Button {
                    manager.resumeTask(task.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Reprendre « \(task.fileName) »")
            }
            if task.canRetry {
                Button {
                    manager.retryTask(task.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Relancer « \(task.fileName) »")
            }
            if task.canCancel {
                Button {
                    withAnimation {
                        manager.cancelTask(task.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Annuler « \(task.fileName) »")
            } else {
                // Tâche soldée (ni active ni en pause) : préavis visuel plus
                // bouton de retrait individuel de la liste.
                switch task.status {
                case .completed:
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        removeButton(for: task)
                    }
                case .failed:
                    HStack(spacing: 14) {
                        if !task.canRetry {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        removeButton(for: task)
                    }
                case .queued, .inProgress:
                    // Inatteignable : une tâche active ou en pause a
                    // `canCancel == true` et prend la branche ci-dessus.
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func removeButton(for task: UploadTaskItem) -> some View {
        Button {
            withAnimation {
                manager.removeTask(task.id)
            }
        } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Retirer « \(task.fileName) » de la liste")
    }
}
