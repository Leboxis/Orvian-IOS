import SwiftUI

/// Onglet « Tag » : catégories kDrive du drive, puis fichiers de la
/// catégorie sélectionnée (grille avec navigation dans les dossiers).
///
/// La pile utilise `NavigationPath` car elle mélange des valeurs `Category`
/// et `DriveFile` ; `trail` maintient les noms pour le breadcrumb.
struct TagsView: View {
    let driveId: Int
    let router: ViewerRouter

    @State private var categories: [Category] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var path = NavigationPath()
    @State private var trail: [String] = []
    /// Affichage des catégories : grille (défaut) ou liste.
    @AppStorage("tagsLayout") private var layout = CategoryLayout.grid

    private let service = KDriveService()

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                layout = layout == .grid ? .list : .grid
                            }
                        } label: {
                            Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                        }
                        .accessibilityLabel(layout == .grid ? "Afficher en liste" : "Afficher en grille")
                    }
                }
                .navigationDestination(for: Category.self) { category in
                    CategoryFilesView(
                        category: category,
                        driveId: driveId,
                        router: router,
                        onOpenFolder: { folder in
                            push(folder)
                        }
                    )
                }
                .navigationDestination(for: DriveFile.self) { directory in
                    DirectoryView(
                        directory: directory,
                        driveId: driveId,
                        crumbs: trail,
                        router: router,
                        onOpenFolder: { folder in
                            push(folder)
                        }
                    )
                }
        }
        .onChange(of: path.count) { _, newCount in
            if trail.count > newCount {
                trail.removeLast(trail.count - newCount)
            }
        }
        .task {
            await loadIfNeeded()
        }
    }

    private var root: some View {
        Group {
            if isLoading && categories.isEmpty {
                ProgressView("Chargement des tags…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, categories.isEmpty {
                errorState(errorMessage)
            } else if categories.isEmpty {
                EmptyStateView(
                    symbol: "tag",
                    title: "Aucun tag",
                    message: "Les catégories créées dans kDrive apparaîtront ici."
                )
            } else if layout == .grid {
                grid
            } else {
                list
            }
        }
        .navigationTitle("Tag")
        .navigationBarTitleDisplayMode(.large)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: DS.gridSpacing) {
                ForEach(categories) { category in
                    Button {
                        path.append(category)
                        trail.append(category.name)
                    } label: {
                        CategoryGridCell(category: category)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.gridMargin)
            .padding(.top, 6)
            .padding(.bottom, 110)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            await load(force: true)
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: DS.gridSpacing), count: 2)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(categories) { category in
                    Button {
                        path.append(category)
                        trail.append(category.name)
                    } label: {
                        CategoryRow(category: category)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.gridMargin)
            .padding(.top, 6)
            .padding(.bottom, 110)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            await load(force: true)
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Impossible de charger", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Réessayer") {
                Task { await load(force: true) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func push(_ folder: DriveFile) {
        path.append(folder)
        trail.append(folder.name)
    }

    private func loadIfNeeded() async {
        guard categories.isEmpty, !isLoading else { return }
        await load(force: false)
    }

    private func load(force: Bool) async {
        if force || categories.isEmpty {
            isLoading = categories.isEmpty
        }
        do {
            categories = try await service.categories(driveId: driveId)
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

private struct CategoryRow: View {
    let category: Category

    private var tint: Color {
        Color(hex: category.color) ?? .accentColor
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if let uses = category.userUses, uses > 0 {
                    Text("\(uses) élément\(uses > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}

/// Carte de catégorie pour le mode grille.
private struct CategoryGridCell: View {
    let category: Category

    private var tint: Color {
        Color(hex: category.color) ?? .accentColor
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tag.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 2) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let uses = category.userUses, uses > 0 {
                    Text("\(uses) élément\(uses > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}

/// Modes d'affichage des catégories dans l'onglet Tag.
enum CategoryLayout: String {
    case list
    case grid
}

/// Grille des fichiers d'une catégorie.
struct CategoryFilesView: View {
    let category: Category
    let driveId: Int
    let router: ViewerRouter
    let onOpenFolder: (DriveFile) -> Void

    @State private var viewModel: FileGridViewModel

    init(
        category: Category,
        driveId: Int,
        router: ViewerRouter,
        onOpenFolder: @escaping (DriveFile) -> Void
    ) {
        self.category = category
        self.driveId = driveId
        self.router = router
        self.onOpenFolder = onOpenFolder
        _viewModel = State(initialValue: FileGridViewModel(source: .category(category.id), driveId: driveId))
    }

    var body: some View {
        FileGridView(
            viewModel: viewModel,
            onOpenDirectory: onOpenFolder,
            onOpenFile: { file, siblings in
                router.open(file, siblings: siblings)
            }
        )
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
