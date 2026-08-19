import SwiftUI

/// Interface détaillée affichant la liste et l'état de chaque upload.
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
                            Text("\(Int(manager.overallProgress * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Fichiers") {
                    if manager.tasks.isEmpty {
                        Text("Aucun transfert en cours")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.tasks) { task in
                            uploadRow(task)
                        }
                    }
                }
            }
            .navigationTitle("Transferts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if manager.activeTasksCount == 0 && !manager.tasks.isEmpty {
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
        } else if manager.hasFailures {
            return "Transferts terminés avec erreur"
        } else {
            return "Tous les transferts sont terminés"
        }
    }

    @ViewBuilder
    private func uploadRow(_ task: UploadTaskItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(ByteFormatter.format(task.totalBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if case let .inProgress(progress) = task.status {
                    ProgressView(value: progress)
                        .tint(Color.accentColor)
                    Text("\(Int(progress * 100)) %")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if case let .failed(message) = task.status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            switch task.status {
            case .queued:
                Text("En attente")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case let .inProgress(progress):
                Text("\(Int(progress * 100)) %")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
