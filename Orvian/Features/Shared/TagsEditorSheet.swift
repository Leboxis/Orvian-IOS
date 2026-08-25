import SwiftUI

/// Éditeur de tags d'un élément (fiche fichier, lecteur vidéo…).
/// Reprend exactement les cartes de la grille de l'onglet Tag ; seule une
/// coche distingue les tags déjà appliqués au fichier.
struct TagsEditorSheet: View {
    let driveId: Int
    let file: DriveFile
    /// État des coches à la réouverture : sans lui, la feuille repartirait
    /// des catégories figées du modèle `file`, périmées après une première
    /// édition dans la même session. L'appelant qui suit les changements
    /// (lecteur vidéo…) le renseigne ; sinon repli sur le fichier.
    var initialAppliedIds: Set<Int>?
    let onChanged: ((Category, Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var categories: [Category] = []
    @State private var appliedCategoryIds: Set<Int>
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let service = KDriveService()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.gridSpacing), count: 2)

    init(
        driveId: Int,
        file: DriveFile,
        initialAppliedIds: Set<Int>? = nil,
        onChanged: ((Category, Bool) -> Void)?
    ) {
        self.driveId = driveId
        self.file = file
        self.initialAppliedIds = initialAppliedIds
        self.onChanged = onChanged
        _appliedCategoryIds = State(initialValue: initialAppliedIds ?? Set((file.categories ?? []).map(\.categoryId)))
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
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: DS.gridSpacing) {
                            ForEach(orderedCategories) { category in
                                tagCell(category)
                            }
                        }
                        .padding(.horizontal, DS.gridMargin)
                        .padding(.top, 6)
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                        Color.clear.frame(height: 100)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .task { await load() }
    }

    /// Même carte que la grille dédiée, enrichie d'une coche de sélection.
    private func tagCell(_ category: Category) -> some View {
        let isApplied = appliedCategoryIds.contains(category.id)
        return Button {
            Task { await toggle(category) }
        } label: {
            TagGridCard(category: category)
                .overlay(alignment: .topTrailing) {
                    if isApplied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(Color.accentColor, in: Circle())
                            .padding(8)
                    }
                }
                .overlay {
                    if isApplied {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Même ordre que l'onglet Tag : les catégories récemment utilisées sont
    /// placées en premier, puis les autres par ordre alphabétique.
    private var orderedCategories: [Category] {
        categories.sorted { lhs, rhs in
            switch (TagUsageStore.lastUsed(driveId: driveId, categoryId: lhs.id),
                    TagUsageStore.lastUsed(driveId: driveId, categoryId: rhs.id)) {
            case let (lhsDate?, rhsDate?):
                return lhsDate > rhsDate
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        async let categoriesTask = loadCategories()
        // Les listes (`with=is_favorite,categories`) fournissent les coches ;
        // la fiche individuelle n'est consultée que si elles manquent
        // (recherche par tag…). L'appelant qui suit déjà les changements
        // garde la main sur les coches.
        if initialAppliedIds == nil {
            if let ids = file.categories {
                appliedCategoryIds = Set(ids.map(\.categoryId))
            } else if let info = try? await service.fileInfo(driveId: driveId, fileId: file.id),
                      let infoCategories = info.categories {
                appliedCategoryIds = Set(infoCategories.map(\.categoryId))
            }
        }
        let cats = await categoriesTask
        categories = cats
    }

    /// Tags du drive via le cache de session partagé.
    private func loadCategories() async -> [Category] {
        await CategoryLibrary.shared.ensureLoaded(for: driveId)
        return Array(CategoryLibrary.shared.categories(for: driveId).values)
    }

    private func toggle(_ category: Category) async {
        let isApplying = !appliedCategoryIds.contains(category.id)
        if isApplying {
            appliedCategoryIds.insert(category.id)
        } else {
            appliedCategoryIds.remove(category.id)
        }
        errorMessage = nil
        do {
            if isApplying {
                try await service.addCategory(driveId: driveId, fileId: file.id, categoryId: category.id)
                TagUsageStore.markUsed(driveId: driveId, categoryId: category.id)
            } else {
                try await service.removeCategory(driveId: driveId, fileId: file.id, categoryId: category.id)
            }
            onChanged?(category, isApplying)
        } catch {
            if isApplying {
                appliedCategoryIds.remove(category.id)
            } else {
                appliedCategoryIds.insert(category.id)
            }
            errorMessage = "Impossible de modifier le tag : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}
