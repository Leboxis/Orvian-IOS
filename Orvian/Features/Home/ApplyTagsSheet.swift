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

    init(driveId: Int, files: [DriveFile], onDone: @escaping ([TagChange]) async -> Void) {
        self.driveId = driveId
        self.files = files
        self.onDone = onDone
    }

    @Environment(\.dismiss) private var dismiss
    @State private var categories: [Category] = []
    @State private var addIDs: Set<Int> = []
    @State private var removeIDs: Set<Int> = []
    // Only API-confirmed membership overrides the immutable opening snapshot.
    @State private var confirmedTagOverrides: [Int: [Int: Bool]] = [:]
    @State private var isLoading = true
    @State private var busy = false
    @State private var errorMessage: String?

    @State private var mutationCredentialFingerprint = TokenStore.credentialFingerprint()
    private var isCurrentMutationSession: Bool {
        !Task.isCancelled && mutationCredentialFingerprint != nil
            && mutationCredentialFingerprint == TokenStore.credentialFingerprint()
    }
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
                                .disabled(busy)
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
        files.filter { hasCategory(categoryId, file: $0) }.count
    }

    private func hasCategory(_ categoryId: Int, file: DriveFile) -> Bool {
        confirmedTagOverrides[file.id]?[categoryId]
            ?? (file.categories ?? []).contains { $0.categoryId == categoryId }
    }

    /// Retry (or a corrected selection) only targets membership not yet confirmed.
    private func pendingFiles(categoryId: Int, isAdd: Bool) -> [DriveFile] {
        files.filter { hasCategory(categoryId, file: $0) != isAdd }
    }

    private func reconcile(_ changes: [TagChange]) {
        for change in changes {
            confirmedTagOverrides[change.file.id, default: [:]][change.categoryId] = change.isAdd
        }
        addIDs = Set(addIDs.filter { !pendingFiles(categoryId: $0, isAdd: true).isEmpty })
        removeIDs = Set(removeIDs.filter { !pendingFiles(categoryId: $0, isAdd: false).isEmpty })
    }

    private func state(of categoryId: Int) -> TagState {
        let count = countHaving(categoryId)
        if count == 0 { return .none }
        if count == files.count { return .all }
        return .partial
    }

    private func toggle(_ category: Category) {
        guard !busy else { return }
        errorMessage = nil
        let id = category.id
        switch state(of: id) {
        case .none:
            // Bascule réversible : ajout ↔ annulation.
            if addIDs.contains(id) {
                addIDs.remove(id)
            } else {
                addIDs.insert(id)
                removeIDs.remove(id)
            }
        case .all:
            // Bascule réversible : retrait ↔ annulation.
            if removeIDs.contains(id) {
                removeIDs.remove(id)
            } else {
                removeIDs.insert(id)
                addIDs.remove(id)
            }
        case .partial:
            // Cycle : compléter vers tous → retirer de tous → retour à l'état initial.
            if addIDs.contains(id) {
                addIDs.remove(id)
                removeIDs.insert(id)
            } else if removeIDs.contains(id) {
                removeIDs.remove(id)
            } else {
                addIDs.insert(id)
                removeIDs.remove(id)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        await CategoryLibrary.shared.ensureLoaded(for: driveId)
        categories = Array(CategoryLibrary.shared.categories(for: driveId).values)
    }

    private func apply() async {
        guard !busy, isCurrentMutationSession else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        let toAdd = addIDs
        let toRemove = removeIDs

        // Appel groupé du doc (`POST/DELETE …/files/categories/{id}` avec
        // `{"file_ids": […]}`) : une requête par tag au lieu d'une par fichier.
        // En cas d'échec groupé, repli sur l'ancien chemin un-par-un pour
        // conserver les succès partiels au lieu de tout marquer en erreur.
        var appliedChanges: [TagChange] = []
        var firstErrorDescription: String?

        for categoryId in toRemove.sorted() {
            guard isCurrentMutationSession else { return }
            let targets = pendingFiles(categoryId: categoryId, isAdd: false)
            guard !targets.isEmpty else { continue }
            let fileIds = targets.map(\.id)
            do {
                try await service.removeCategory(driveId: driveId, fileIds: fileIds, categoryId: categoryId, credentialFingerprint: mutationCredentialFingerprint)
                guard isCurrentMutationSession else { return }
                appliedChanges += targets.map { TagChange(file: $0, categoryId: categoryId, isAdd: false) }
            } catch {
                guard isCurrentMutationSession else { return }
                let fallback = await applyOneByOne(files: targets, categoryId: categoryId, isAdd: false)
                guard isCurrentMutationSession else { return }
                appliedChanges += fallback.changes
                if firstErrorDescription == nil {
                    firstErrorDescription = fallback.error
                }
            }
        }
        for categoryId in toAdd.sorted() {
            guard isCurrentMutationSession else { return }
            let targets = pendingFiles(categoryId: categoryId, isAdd: true)
            guard !targets.isEmpty else { continue }
            let fileIds = targets.map(\.id)
            do {
                try await service.addCategory(driveId: driveId, fileIds: fileIds, categoryId: categoryId, credentialFingerprint: mutationCredentialFingerprint)
                guard isCurrentMutationSession else { return }
                appliedChanges += targets.map { TagChange(file: $0, categoryId: categoryId, isAdd: true) }
            } catch {
                guard isCurrentMutationSession else { return }
                let fallback = await applyOneByOne(files: targets, categoryId: categoryId, isAdd: true)
                guard isCurrentMutationSession else { return }
                appliedChanges += fallback.changes
                if firstErrorDescription == nil {
                    firstErrorDescription = fallback.error
                }
            }
        }

        // Les modifications confirmées parviennent aux grilles même en cas
        // d'échec partiel : seules les paires en erreur restent à refaire.
        guard isCurrentMutationSession else { return }
        reconcile(appliedChanges)
        if !appliedChanges.isEmpty {
            await onDone(appliedChanges)
        }
        guard isCurrentMutationSession else { return }
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

    /// Repli un-par-un (4 requêtes simultanées) quand l'appel groupé échoue :
    /// récupère les succès partiels au lieu de perdre toute la sélection.
    private func applyOneByOne(files: [DriveFile], categoryId: Int, isAdd: Bool) async -> (changes: [TagChange], error: String?) {
        let results = await mapBounded(files, concurrency: 4) { file -> Result<TagChange, TagApplyError> in
            guard await self.isCurrentMutationSession else {
                return .failure(TagApplyError(message: "Session terminée"))
            }
            do {
                if isAdd {
                    try await self.service.addCategory(driveId: self.driveId, fileId: file.id, categoryId: categoryId, credentialFingerprint: self.mutationCredentialFingerprint)
                    return .success(TagChange(file: file, categoryId: categoryId, isAdd: true))
                } else {
                    try await self.service.removeCategory(driveId: self.driveId, fileId: file.id, categoryId: categoryId, credentialFingerprint: self.mutationCredentialFingerprint)
                    return .success(TagChange(file: file, categoryId: categoryId, isAdd: false))
                }
            } catch {
                return .failure(TagApplyError(message: (error as? APIError)?.errorDescription ?? error.localizedDescription))
            }
        }
        var changes: [TagChange] = []
        var firstError: String?
        for result in results {
            switch result {
            case let .success(change):
                changes.append(change)
            case let .failure(error):
                if firstError == nil { firstError = error.message }
            }
        }
        return (changes, firstError)
    }
}

