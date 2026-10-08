import SwiftUI

struct FolderScanSheet: View {
    let scanner: FolderImageScanner
    let store: ImageClassificationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let progress = scanner.progress {
                    Section {
                        Label(progress.directoryName, systemImage: "folder")
                            .font(.headline)
                        Text("Images directement présentes dans ce dossier")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Progression") {
                        if progress.phase == .enumerating {
                            ProgressView("Recherche des images…")
                        } else if let total = progress.total {
                            if total == 0 {
                                Text("Aucune image dans ce dossier.")
                            } else {
                                ProgressView(value: Double(progress.processed), total: Double(total))
                                LabeledContent("Images traitées", value: "\(progress.processed) / \(total)")
                            }
                        }
                        LabeledContent("SFW", value: "\(scanner.sfwCount)")
                        LabeledContent("NSFW", value: "\(scanner.nsfwCount)")
                        if progress.reused > 0 {
                            LabeledContent("Résultats réutilisés", value: "\(progress.reused)")
                        }
                        if progress.failed > 0 {
                            LabeledContent("Non analysées après une erreur", value: "\(progress.failed)")
                        }
                        switch progress.phase {
                        case .completed: Label("Scan terminé", systemImage: "checkmark.circle")
                        case .cancelled: Label("Scan interrompu", systemImage: "pause.circle")
                        case .failed:
                            Label(progress.errorMessage ?? "Le scan est incomplet.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        case .enumerating, .analyzing: EmptyView()
                        }
                        if let error = store.persistenceError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }

                    Section {
                        LabeledContent("Seuil NSFW", value: "\(Int((store.threshold * 100).rounded())) %")
                        Slider(value: Binding(
                            get: { Double(store.threshold) },
                            set: { store.threshold = Float($0) }
                        ), in: 0.50...0.99, step: 0.01)
                        .accessibilityLabel("Seuil de classification NSFW")
                    } footer: {
                        Text("Un seuil plus bas classe davantage d’images NSFW. Les filtres utilisent ce seuil sans relancer l’analyse.")
                    }

                    if scanner.isRunning {
                        Section {
                            Button("Annuler le scan", role: .destructive) { scanner.cancel() }
                        }
                    }
                    Section {
                        Text("Analyse locale sur cet appareil. Les miniatures nécessaires sont récupérées depuis votre espace de fichiers. Les GIF sont analysés sur une image fixe.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Retrouvez les résultats dans Filtres → Classification des images.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Aucun scan en cours.")
                }
            }
            .navigationTitle("Scan du dossier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
