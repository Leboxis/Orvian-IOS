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

    /// Options de tri et de filtrage (bouton filtre de l'Accueil).
    var filters: FileFilters = .init()

    /// Remonte true quand l'utilisateur a défilé vers le bas (dépassé le haut).
    var onScrolledPastTop: ((Bool) -> Void)?

    /// Pull-to-refresh (désactivé sur l'Accueil, remplacé par la barre de recherche).
    var allowsPullToRefresh = true

    @ObservedObject private var mediaMetadata = MediaMetadataStore.shared

    var body: some View {
        scrollContent
            .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y > 0 }) { _, scrolledDown in
                onScrolledPastTop?(scrolledDown)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .task {
                await viewModel.loadIfNeeded()
                onInitialLoad?(viewModel.items)
            }
            .task(id: filterTaskKey) {
                await mediaMetadata.resolveAll(driveId: viewModel.driveId, items: viewModel.items)
            }
    }

    /// Relance la résolution des métadonnées vidéo uniquement quand un tri ou
    /// un filtre en a besoin.
    private var filterTaskKey: String {
        let needsMetadata = filters.sort == .duration || !filters.orientations.isEmpty
        return needsMetadata ? "resolve-\(viewModel.items.count)" : "none"
    }

    @ViewBuilder
    private var scrollContent: some View {
        if allowsPullToRefresh {
            baseScroll
                .refreshable {
                    await viewModel.reload()
                }
        } else {
            baseScroll
        }
    }

    private var baseScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                content
            }
            .padding(.horizontal, DS.gridMargin)
            .padding(.top, 6)
            .padding(.bottom, 110) // barre flottante
        }
    }

    // MARK: - Contenu

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Éléments après filtres (type, orientation, recherche) et tri.
    private var visibleItems: [DriveFile] {
        var result = viewModel.items

        switch filters.media {
        case .all: break
        case .videos: result = result.filter(\.isVideo)
        case .images: result = result.filter(\.isImage)
        case .other: result = result.filter { !$0.isVideo && !$0.isImage }
        }

        if !filters.orientations.isEmpty {
            result = result.filter { file in
                guard file.isVideo, let info = mediaMetadata.info(for: file.id) else { return false }
                return filters.orientations.contains(info.orientation)
            }
        }

        if isSearching {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        switch filters.sort {
        case .original:
            break
        case .date:
            result = result.sorted {
                ($0.lastModifiedAt ?? $0.addedAt ?? 0) > ($1.lastModifiedAt ?? $1.addedAt ?? 0)
            }
        case .type:
            result = result.sorted {
                $0.fileKind.label.localizedCaseInsensitiveCompare($1.fileKind.label) == .orderedAscending
            }
        case .size:
            result = result.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
        case .duration:
            result = result.sorted {
                (mediaMetadata.info(for: $0.id)?.duration ?? -1) > (mediaMetadata.info(for: $1.id)?.duration ?? -1)
            }
        }

        return result
    }

    /// Message quand aucun élément ne correspond aux filtres ou à la recherche.
    private var noResultsMessage: String {
        if isSearching {
            return "Aucun fichier ne correspond à « \(searchText.trimmingCharacters(in: .whitespacesAndNewlines)) »."
        }
        return "Aucun fichier ne correspond aux filtres sélectionnés."
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isInitialLoading {
            skeleton
        } else if let message = viewModel.errorMessage, viewModel.items.isEmpty {
            errorState(message)
        } else if viewModel.items.isEmpty {
            emptyState
        } else if visibleItems.isEmpty {
            ContentUnavailableView {
                Label("Aucun résultat", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(noResultsMessage)
            }
            .padding(.top, 60)
        } else if let grouping, !isSearching && !filters.isActive {
            ForEach(viewModel.groups(by: grouping.component, title: grouping.title)) { group in
                SectionHeader(title: group.title)
                grid(for: group.files)
            }
            footer
        } else {
            grid(for: visibleItems)
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
