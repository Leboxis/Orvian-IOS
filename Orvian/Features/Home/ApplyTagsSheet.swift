import SwiftUI

/// Feuille « Mettre des tags » : affiche les tags déjà présents sur la
/// sélection (coche = sur tous les éléments, tiret = sur certains) et permet
/// de les ajouter ou de les retirer en une passe (échecs partiels signalés).
/// Modification de tag confirmée par l'API, transmise à la fermeture de la
/// feuille pour une mise à jour locale des grilles (pastilles) sans
/// rechargement réseau.
struct TagChange {
    let file: DriveFile
    let categoryId: Int
    let isAdd: Bool
}

/// Échec d'application d'un tag sur un élément, porteur du message affiché.
private struct TagApplyError: Error {
    let message: String
}

struct ApplyTagsSheet: View {
    let driveId: Int
    let files: [DriveFile]
    let onDone: ([TagChange]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var categories: [Category] = []
    @State private var addIDs: Set<Int> = []
    @State private var removeIDs: Set<Int> = []
    @State private var isLoading = true
    @State private var busy = false
    @State private var errorMessage: String?

    private let service = KDriveService()

    private enum TagState {
        case none
        case partial
        case all
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Chargement des tags…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if categories.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun tag", systemImage: "tag")
                    } description: {
                        Text("Créez des tags dans l'onglet Tag pour les appliquer ici.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(categories) { category in
                                Button {
                                    toggle(category)
                                } label: {
                                    HStack(spacing: 12) {
                                        Circle()
                                            .fill(Color(hex: category.color) ?? .gray)
                                            .frame(width: 12, height: 12)
                                        Text(category.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        rowSymbol(category)
                                    }
                                }
                            }
                        } header: {
                            Text("Tags des \(files.count) élément\(files.count > 1 ? "s" : "") sélectionné\(files.count > 1 ? "s" : "")")
                        } footer: {
                            Text("Coche : présent sur tous les éléments · tiret : présent sur certains. Touchez une coche pour retirer le tag de toute la sélection.")
                        }
                        if let errorMessage {
                            Section {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mettre des tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .disabled(busy)
                    .accessibilityLabel("Annuler")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Appliquer") {
                            Task { await apply() }
                        }
                        .disabled(addIDs.isEmpty && removeIDs.isEmpty)
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func rowSymbol(_ category: Category) -> some View {
        let symbol = Image(systemName: "circle")
            .font(.system(size: 18))
        if removeIDs.contains(category.id) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 18))
        } else if addIDs.contains(category.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 18))
        } else {
            switch state(of: category.id) {
            case .all:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 18))
            case .partial:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 18))
            case .none:
                symbol.foregroundStyle(.secondary)
            }
        }
    }

    /// Nombre d'éléments sélectionnés portant déjà ce tag (les listes kDrive
    /// renvoient `categories` avec `with=is_favorite,categories`).
    private func countHaving(_ categoryId: Int) -> Int {
        files.count { file in
            (file.categories ?? []).contains { $0.categoryId == categoryId }
        }
    }

    private func state(of categoryId: Int) -> TagState {
        let count = countHaving(categoryId)
        if count == 0 { return .none }
        if count == files.count { return .all }
        return .partial
    }

    private func toggle(_ category: Category) {
        switch state(of: category.id) {
        case .none, .partial:
            addIDs.insert(category.id)
            removeIDs.remove(category.id)
        case .all:
            removeIDs.insert(category.id)
            addIDs.remove(category.id)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        await CategoryLibrary.shared.ensureLoaded(for: driveId)
        categories = Array(CategoryLibrary.shared.categories(for: driveId).values)
    }

    private func apply() async {
        busy = true
        defer { busy = false }
        let toAdd = addIDs
        let toRemove = removeIDs

        // Petits lots de 4 requêtes simultanées : appliquer des tags sur une
        // grande sélection ne défile plus les appels API un par un.
        var work: [(file: DriveFile, categoryId: Int, isAdd: Bool)] = []
        for file in files {
            for categoryId in toRemove {
                work.append((file, categoryId, false))
            }
        }
        for file in files {
            for categoryId in toAdd {
                work.append((file, categoryId, true))
            }
        }

        let results = await mapBounded(work, concurrency: 4) { item -> Result<TagChange, TagApplyError> in
            do {
                if item.isAdd {
                    try await service.addCategory(driveId: driveId, fileId: item.file.id, categoryId: item.categoryId)
                    return .success(TagChange(file: item.file, categoryId: item.categoryId, isAdd: true))
                } else {
                    try await service.removeCategory(driveId: driveId, fileId: item.file.id, categoryId: item.categoryId)
                    return .success(TagChange(file: item.file, categoryId: item.categoryId, isAdd: false))
                }
            } catch {
                return .failure(TagApplyError(message: (error as? APIError)?.errorDescription ?? error.localizedDescription))
            }
        }

        var appliedChanges: [TagChange] = []
        var firstErrorDescription: String?
        for result in results {
            switch result {
            case let .success(change):
                appliedChanges.append(change)
            case let .failure(error):
                if firstErrorDescription == nil { firstErrorDescription = error.message }
            }
        }

        // Les modifications confirmées parviennent aux grilles même en cas
        // d'échec partiel : seules les paires en erreur restent à refaire.
        if !appliedChanges.isEmpty {
            await onDone(appliedChanges)
        }
        if let firstErrorDescription {
            var details: [String] = []
            if !appliedChanges.isEmpty {
                let addedCount = appliedChanges.filter(\.isAdd).count
                let removedCount = appliedChanges.count - addedCount
                if addedCount > 0 {
                    details.append("\(addedCount) tag\(addedCount > 1 ? "s" : "") appliqué\(addedCount > 1 ? "s" : "")")
                }
                if removedCount > 0 {
                    details.append("\(removedCount) tag\(removedCount > 1 ? "s" : "") retiré\(removedCount > 1 ? "s" : "")")
                }
            }
            let summary = details.isEmpty ? "Aucune modification" : details.joined(separator: ", ")
            errorMessage = "\(summary) sur \(files.count) élément\(files.count > 1 ? "s" : "") — \(firstErrorDescription)"
        } else {
            dismiss()
        }
    }
}
