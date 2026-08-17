import SwiftUI

/// Grille 3 colonnes réutilisable, avec pagination infinie et préchargement.
struct FileGridView: View {
    var viewModel: FileGridViewModel

    /// Groupement des sections : composant de calendrier + titre (Actualité → jour, Média → mois). nil → grille plate.
    var grouping: (component: Calendar.Component, title: (Date) -> String)?

    /// Navigation dans un dossier (onglet Fichiers uniquement).
    var onOpenDirectory: ((DriveFile) -> Void)?

    /// Ouverture d'une visionneuse (image/vidéo) avec ses voisins pour le pager.
    var onOpenFile: ((DriveFile, [DriveFile]) -> Void)?

    /// Filtre client des éléments affichés (barre de recherche de l'Accueil).
    var searchText: String = ""
    
    /// Options de tri et de filtrage (bouton filtre de l'Accueil).
    var filters: FileFilters = .init()

    /// Remonte true quand l'utilisateur défile vers le haut (offset négatif).
    var onScrolledPastTop: ((Bool) -> Void)?

    /// Décalage ajouté en haut du contenu (barre de recherche flottante) pour
    /// que la première rangée ne soit jamais masquée.
    var contentTopInset: CGFloat = 0

    /// Pull-to-refresh (désactivé sur l'Accueil, remplacé par la barre de recherche).
    var allowsPullToRefresh = true

    /// Mode sélection (corbeille) : le tap coche au lieu d'ouvrir.
    var selectionMode = false

    /// Identifiants des éléments sélectionnés (mode sélection).
    var selectedIDs: Set<Int> = []

    /// Appelé quand l'utilisateur tape une carte en mode sélection.
    var onToggleSelection: ((DriveFile) -> Void)?

    private let mediaMetadata = MediaMetadataStore.shared
    @State private var metadataRevision = 0

    private var needsVideoMetadata: Bool {
        filters.sort == .duration || filters.orientation != nil
    }

    var body: some View {
        scrollContent
            .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y < 0 }) { oldValue, newValue in
                if oldValue != newValue {
                    onScrolledPastTop?(newValue)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .task(id: viewModel.source) {
                await viewModel.loadIfNeeded()
            }
            .task(id: filterTaskKey) {
                guard needsVideoMetadata else { return }
                await mediaMetadata.resolveAll(driveId: viewModel.driveId, items: viewModel.items)
            }
            .onReceive(mediaMetadata.$revision) { newRev in
                if needsVideoMetadata {
                    metadataRevision = newRev
                }
            }
    }

    /// Relance la résolution des métadonnées vidéo uniquement quand un tri ou
    /// un filtre en a besoin.
    private var filterTaskKey: String {
        return needsVideoMetadata ? "resolve-\(viewModel.items.count)" : "none"
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
            .padding(.top, 6 + contentTopInset)
            .padding(.bottom, 110) // barre flottante
        }
    }

    // MARK: - Contenu

    private var searchKeywords: [String] {
        searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private var isSearching: Bool {
        !searchKeywords.isEmpty
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

        if let orientation = filters.orientation {
            result = result.filter { file in
                guard file.isVideo, let info = mediaMetadata.info(for: file.id) else { return false }
                return info.orientation == orientation
            }
        }

        if isSearching {
            result = result.filter { $0.matchesSearchKeywords(searchKeywords) }
        }

        switch filters.sort {
        case .original:
            break
        case .modifiedDate:
            result = result.sorted {
                let lhs = $0.lastModifiedAt ?? 0
                let rhs = $1.lastModifiedAt ?? 0
                return filters.direction == .descending ? lhs > rhs : lhs < rhs
            }
        case .addedDate:
            result = result.sorted {
                let lhs = $0.addedAt ?? 0
                let rhs = $1.addedAt ?? 0
                return filters.direction == .descending ? lhs > rhs : lhs < rhs
            }
        case .type:
            result = result.sorted {
                let comparison = $0.fileKind.label.localizedCaseInsensitiveCompare($1.fileKind.label)
                return filters.direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        case .size:
            result = result.sorted {
                let lhs = $0.size ?? -1
                let rhs = $1.size ?? -1
                return filters.direction == .descending ? lhs > rhs : lhs < rhs
            }
        case .duration:
            result = result.sorted {
                let lhs = mediaMetadata.info(for: $0.id)?.duration ?? -1
                let rhs = mediaMetadata.info(for: $1.id)?.duration ?? -1
                return filters.direction == .descending ? lhs > rhs : lhs < rhs
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
            enabled: selectionMode || !file.isDirectory || onOpenDirectory != nil,
            selectionMode: selectionMode,
            isTrashed: viewModel.source == .trash,
            isSelected: selectedIDs.contains(file.id),
            onToggleSelection: onToggleSelection == nil ? nil : { onToggleSelection?(file) },
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
                if selectionMode {
                    onToggleSelection?(file)
                } else if file.isDirectory {
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

    /// Apparition d'une carte : pagination + préchargement régulé des suivantes.
    private func appeared(file: DriveFile, index: Int, in siblings: [DriveFile]) {
        if index >= siblings.count - 6 {
            Task { await viewModel.loadMoreIfNeeded() }
        }
        // Préchargement par lot toutes les 3 cellules pour ne pas saturer la file async au scroll rapide
        guard index % 3 == 0 else { return }
        let ahead = siblings.dropFirst(index + 1).prefix(6)
        let thumbnailIds = ahead.filter { $0.fileKind.supportsThumbnail }.map(\.id)
        if !thumbnailIds.isEmpty {
            Task { await ThumbnailProvider.shared.prefetch(driveId: viewModel.driveId, fileIds: Array(thumbnailIds), isTrashed: viewModel.source == .trash) }
        }
        // URLs temporaires des vidéos à venir : lecture quasi immédiate au tap.
        // Inutile pour la corbeille (les fichiers y sont inaccessibles).
        guard viewModel.source != .trash else { return }
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
        case .recents: return "clock"
        case .mostViewed: return "flame"
        case .category: return "tag"
        case .trash: return "trash"
        case .search: return "magnifyingglass"
        }
    }

    private var emptyTitle: String {
        switch viewModel.source {
        case .directory: return "Dossier vide"
        case .favorites: return "Aucun favori"
        case .recents: return "Aucun upload récent"
        case .mostViewed: return "Aucun média consulté"
        case .category: return "Aucun fichier avec ce tag"
        case .trash: return "Corbeille vide"
        case .search: return "Aucun résultat"
        }
    }
}
