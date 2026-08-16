import SwiftUI

/// Grille 3 colonnes réutilisable, avec pagination infinie et préchargement.
struct FileGridView: View {
    @State var viewModel: FileGridViewModel

    /// Groupement des sections : composant de calendrier + titre (Actualité → jour, Média → mois). nil → grille plate.
    var grouping: (component: Calendar.Component, title: (Date) -> String)?

    /// Navigation dans un dossier (onglet Fichiers uniquement).
    var onOpenDirectory: ((DriveFile) -> Void)?

    /// Ouverture d'une visionneuse (image/vidéo) avec ses voisins pour le pager.
    var onOpenFile: ((DriveFile, [DriveFile]) -> Void)?

    /// Appelé une fois le premier chargement terminé (items à jour).
    var onInitialLoad: (([DriveFile]) -> Void)?

    /// Filtre client des éléments affichés (barre de recherche de l'Accueil).
    var searchText: String = ""

    /// Remonte true quand l'utilisateur a défilé vers le bas (dépassé le haut).
    var onScrolledPastTop: ((Bool) -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                if onScrolledPastTop != nil {
                    Color.clear
                        .frame(height: 1)
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            onScrolledPastTop?(!visible)
                        }
                }
                content
            }
            .padding(.horizontal, DS.gridMargin)
            .padding(.top, 6)
            .padding(.bottom, 110) // barre flottante
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            await viewModel.reload()
        }
        .task {
            await viewModel.loadIfNeeded()
            onInitialLoad?(viewModel.items)
        }
    }

    // MARK: - Contenu

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredItems: [DriveFile] {
        guard isSearching else { return viewModel.items }
        return viewModel.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isInitialLoading {
            skeleton
        } else if let message = viewModel.errorMessage, viewModel.items.isEmpty {
            errorState(message)
        } else if viewModel.items.isEmpty {
            emptyState
        } else if isSearching && filteredItems.isEmpty {
            ContentUnavailableView {
                Label("Aucun résultat", systemImage: "magnifyingglass")
            } description: {
                Text("Aucun fichier ne correspond à « \(searchText.trimmingCharacters(in: .whitespacesAndNewlines)) ».")
            }
            .padding(.top, 60)
        } else if let grouping, !isSearching {
            ForEach(viewModel.groups(by: grouping.component, title: grouping.title)) { group in
                SectionHeader(title: group.title)
                grid(for: group.files)
            }
            footer
        } else {
            grid(for: filteredItems)
            footer
        }
    }

    private func grid(for files: [DriveFile]) -> some View {
        LazyVGrid(columns: columns, spacing: DS.gridSpacing) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                cell(file, index: index, siblings: files)
            }
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: DS.gridSpacing), count: 3)
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView()
                Text("Chargement…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if viewModel.errorMessage != nil, !viewModel.items.isEmpty {
            retryRow
        }
    }

    private var retryRow: some View {
        Button {
            Task { await viewModel.loadMoreIfNeeded() }
        } label: {
            Label("Réessayer", systemImage: "arrow.clockwise")
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Cellule

    private func cell(_ file: DriveFile, index: Int, siblings: [DriveFile]) -> some View {
        FileCardView(
            file: file,
            driveId: viewModel.driveId,
            enabled: !file.isDirectory || onOpenDirectory != nil,
            onToggleFavorite: {
                Task { await viewModel.toggleFavorite(file) }
            },
            onDelete: {
                Task { await viewModel.trash(file) }
            },
            onRename: { newName in
                Task { await viewModel.rename(file, name: newName) }
            },
            action: {
                if file.isDirectory {
                    onOpenDirectory?(file)
                } else {
                    onOpenFile?(file, siblings)
                }
            }
        )
        .onAppear {
            appeared(file: file, index: index, in: siblings)
        }
    }

    /// Apparition d'une carte : pagination + préchargement des suivantes.
    private func appeared(file: DriveFile, index: Int, in siblings: [DriveFile]) {
        if index >= siblings.count - 6 {
            Task { await viewModel.loadMoreIfNeeded() }
        }
        let ahead = siblings.dropFirst(index).prefix(7)
        let thumbnailIds = ahead.dropFirst().map(\.id)
        if !thumbnailIds.isEmpty {
            Task { await ThumbnailProvider.shared.prefetch(driveId: viewModel.driveId, fileIds: Array(thumbnailIds)) }
        }
        // URLs temporaires des vidéos à venir : lecture quasi immédiate au tap.
        let videoIds = ahead.filter { $0.isVideo }.map(\.id)
        if !videoIds.isEmpty {
            Task { await MediaURLCache.shared.prefetch(driveId: viewModel.driveId, fileIds: videoIds) }
        }
    }

    // MARK: - États

    private var skeleton: some View {
        LazyVGrid(columns: columns, spacing: DS.gridSpacing) {
            ForEach(0..<9, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: emptySymbol,
            title: emptyTitle,
            message: "Tirez vers le bas pour rafraîchir."
        )
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Impossible de charger", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Réessayer") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptySymbol: String {
        switch viewModel.source {
        case .directory: return "folder"
        case .favorites: return "star"
        case .category: return "tag"
        }
    }

    private var emptyTitle: String {
        switch viewModel.source {
        case .directory: return "Dossier vide"
        case .favorites: return "Aucun favori"
        case .category: return "Aucun fichier avec ce tag"
        }
    }
}
