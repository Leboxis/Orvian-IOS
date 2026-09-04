import SwiftUI

/// Onglet « Tag » : catégories kDrive du drive, puis fichiers de la
/// catégorie sélectionnée (grille avec navigation dans les dossiers).
///
/// La pile utilise `NavigationPath` car elle mélange des valeurs `Category`
/// et `DriveFile` ; `trail` maintient les noms pour le breadcrumb.
struct TagsView: View {
    let driveId: Int
    let router: ViewerRouter
    @Binding var path: NavigationPath
    /// Noms des éléments de `path` pour le fil d'Ariane ; persiste dans
    /// `TabNavigationState` pour survivre au démontage de l'onglet.
    @Binding var trail: [String]

    @State private var categories: [Category] = []
    @State private var isLoading = false
    /// Évite d'afficher provisoirement « (0) » avant la première réponse API.
    @State private var hasLoadedCategories = false
    @State private var errorMessage: String?
    @State private var operationErrorMessage: String?
    /// Affichage des catégories : grille (défaut) ou liste.
    @AppStorage("tagsLayout") private var layout = CategoryLayout.grid
    /// Nombre de colonnes de la grille, partagé avec l'éditeur de tags.
    @AppStorage("tagGridColumns") private var tagGridColumns = 2
    @State private var showCreateSheet = false

    @State private var tagToRename: Category?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    @State private var tagToDelete: Category?
    @State private var showDeleteConfirm = false

    /// Mode réordonnancement : bouton crayon, flèches haut/bas par tag,
    /// ordre mémorisé par drive via `TagOrderStore`.
    @State private var isReordering = false
    /// Ordre personnalisé (IDs) chargé depuis `TagOrderStore` ; nil → ordre du serveur.
    @State private var customOrder: [Int]?

    private let service = KDriveService()

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                layout = layout == .grid ? .list : .grid
                            }
                        } label: {
                            Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                        }
                        .accessibilityLabel(layout == .grid ? "Afficher en liste" : "Afficher en grille")

                        Button {
                            isReordering.toggle()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(isReordering ? "Terminer le réarrangement" : "Réarranger les tags")

                        Button {
                            showCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Nouveau tag")
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
        .sheet(isPresented: $showCreateSheet) {
            CreateTagSheet(driveId: driveId) {
                Task { await refreshAfterMutation("Le tag a été créé") }
            }
        }
        .alert("Renommer le tag", isPresented: $showRenameAlert) {
            TextField("Nom du tag", text: $renameText)
            Button("Enregistrer") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let tag = tagToRename, !trimmed.isEmpty {
                    Task { await rename(tag, to: trimmed) }
                }
            }
            Button("Annuler", role: .cancel) { }
        }
        .confirmationDialog(
            "Supprimer le tag « \(tagToDelete?.name ?? "") » ?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let tag = tagToDelete {
                    Task { await delete(tag) }
                }
            }
        } message: {
            Text("Le tag sera retiré de tous les fichiers associés.")
        }
        .alert("Action impossible", isPresented: operationErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationErrorMessage ?? "")
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
        .navigationTitle(tagNavigationTitle)
        .navigationBarTitleDisplayMode(.large)
    }

    /// Conserve le titre « Tag » et ajoute le nombre avec une hiérarchie plus
    /// discrète, directement dans le même texte du titre de navigation.
    private var tagNavigationTitle: Text {
        let title = Text("Tag")
        guard hasLoadedCategories else { return title }
        return title + Text(" (\(categories.count))")
            .font(.system(size: 10, weight: .medium))
    }

    /// Ordre d'affichage : ordre personnalisé si l'utilisateur l'a défini
    /// (bouton crayon), sinon l'ordre renvoyé par le serveur. Les tags créés
    /// après un réarrangement sont ajoutés à la fin.
    private var orderedCategories: [Category] {
        guard let customOrder, !customOrder.isEmpty else { return categories }
        let rank = Dictionary(customOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return categories.sorted { lhs, rhs in
            let l = rank[lhs.id] ?? Int.max
            let r = rank[rhs.id] ?? Int.max
            if l != r { return l < r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: DS.gridSpacing) {
                ForEach(orderedCategories) { category in
                    if isReordering {
                        reorderCell(for: category)
                    } else {
                        Button {
                            open(category)
                        } label: {
                            TagGridCard(category: category)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            tagContextMenu(for: category)
                        }
                    }
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
        Array(repeating: GridItem(.flexible(), spacing: DS.gridSpacing), count: max(2, tagGridColumns))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(orderedCategories) { category in
                    if isReordering {
                        reorderCell(for: category)
                    } else {
                        Button {
                            open(category)
                        } label: {
                            CategoryRow(category: category)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            tagContextMenu(for: category)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                tagToDelete = category
                                showDeleteConfirm = true
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }

                            Button {
                                tagToRename = category
                                renameText = category.name
                                showRenameAlert = true
                            } label: {
                                Label("Renommer", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
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

    /// Cellule du mode réarrangement : carte sans navigation, flèches
    /// haut/bas pour déplacer le tag, bordure pour signaler le mode actif.
    /// Reprend la présentation du mode courant (grille ou liste).
    @ViewBuilder
    private func reorderCell(for category: Category) -> some View {
        if layout == .grid {
            TagGridCard(category: category)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        reorderButton(systemName: "arrow.up", accessibilityLabel: "Monter \(category.name)") {
                            move(category, offset: -1)
                        }
                        reorderButton(systemName: "arrow.down", accessibilityLabel: "Descendre \(category.name)") {
                            move(category, offset: 1)
                        }
                    }
                    .padding(6)
                }
        } else {
            CategoryRow(category: category)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                }
                .overlay(alignment: .trailing) {
                    HStack(spacing: 10) {
                        reorderButton(systemName: "arrow.up", accessibilityLabel: "Monter \(category.name)") {
                            move(category, offset: -1)
                        }
                        reorderButton(systemName: "arrow.down", accessibilityLabel: "Descendre \(category.name)") {
                            move(category, offset: 1)
                        }
                    }
                    .padding(.trailing, 38)
                }
        }
    }

    private func reorderButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Déplace un tag de `offset` positions (-1 = vers le haut) dans l'ordre
    /// affiché, puis persiste le nouvel ordre complet.
    private func move(_ category: Category, offset: Int) {
        var ordered = orderedCategories
        guard let index = ordered.firstIndex(where: { $0.id == category.id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        let ids = ordered.map(\.id)
        customOrder = ids
        TagOrderStore.save(ids, driveId: driveId)
    }

    @ViewBuilder
    private func tagContextMenu(for category: Category) -> some View {
        Button {
            tagToRename = category
            renameText = category.name
            showRenameAlert = true
        } label: {
            Label("Renommer", systemImage: "pencil")
        }

        Button(role: .destructive) {
            tagToDelete = category
            showDeleteConfirm = true
        } label: {
            Label("Supprimer", systemImage: "trash")
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

    private func open(_ category: Category) {
        path.append(category)
        trail.append(category.name)
    }

    private func push(_ folder: DriveFile) {
        path.append(folder)
        trail.append(folder.name)
    }

    private func loadIfNeeded() async {
        guard categories.isEmpty, !isLoading else { return }
        if customOrder == nil {
            customOrder = TagOrderStore.order(for: driveId)
        }
        // Bibliothèque partagée déjà chargée cette session (grilles,
        // éditeur de tags, visite précédente) : affichage immédiat sans
        // spinner ni requête. Les mutations locales (création, renommage,
        // suppression) mettent déjà la bibliothèque à jour ; le
        // pull-to-refresh reste la voie explicite pour revalider le serveur.
        let library = CategoryLibrary.shared
        if library.hasLoaded(for: driveId) {
            categories = library.categoryList(for: driveId)
            hasLoadedCategories = true
            return
        }
        await load(force: false)
    }

    private func load(force: Bool) async {
        if force || categories.isEmpty {
            isLoading = categories.isEmpty
        }
        do {
            try await refreshCategories()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func refreshCategories() async throws {
        categories = try await CategoryLibrary.shared.refresh(for: driveId)
        hasLoadedCategories = true
        errorMessage = nil
    }

    private func rename(_ tag: Category, to name: String) async {
        do {
            try await service.updateCategory(driveId: driveId, categoryId: tag.id, name: name, color: tag.color)
        } catch {
            operationErrorMessage = "Renommage impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
            return
        }
        let renamed = Category(
            id: tag.id,
            name: name,
            color: tag.color,
            isPredefined: tag.isPredefined,
            userUses: tag.userUses
        )
        CategoryLibrary.shared.upsert(renamed, for: driveId)
        replaceLocalCategory(renamed)
        await refreshAfterMutation("Le tag a été renommé")
    }

    private func delete(_ tag: Category) async {
        do {
            try await service.deleteCategory(driveId: driveId, categoryId: tag.id)
        } catch {
            operationErrorMessage = "Suppression impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
            return
        }
        CategoryLibrary.shared.remove(categoryId: tag.id, for: driveId)
        categories.removeAll { $0.id == tag.id }
        await refreshAfterMutation("Le tag a été supprimé")
    }

    private func refreshAfterMutation(_ successMessage: String) async {
        do {
            try await refreshCategories()
        } catch {
            operationErrorMessage = "\(successMessage), mais l’actualisation est impossible : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func replaceLocalCategory(_ category: Category) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        categories[index] = category
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationErrorMessage != nil },
            set: { if !$0 { operationErrorMessage = nil } }
        )
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

/// Carte de catégorie pour les grilles de tags.
/// Employée aussi dans l'éditeur de tags afin de conserver une présentation
/// parfaitement cohérente entre l'onglet dédié et le menu d'un fichier.
struct TagGridCard: View {
    let category: Category
    /// Variante resserrée des éditeurs de tags : icône et textes réduits,
    /// compteur d'usage masqué, pour en afficher davantage à l'écran.
    var compact = false

    private var tint: Color {
        Color(hex: category.color) ?? .accentColor
    }

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Image(systemName: "tag.fill")
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)
                .background(tint, in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))

            VStack(spacing: 2) {
                Text(category.name)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.center)
                if !compact, let uses = category.userUses, uses > 0 {
                    Text("\(uses) élément\(uses > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(compact ? 8 : 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
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
    @State private var filters = FileFilters()

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
                router.open(
                    file,
                    siblings: siblings,
                    filters: filters,
                    searchText: "",
                    viewModel: viewModel
                )
            },
            filters: filters
        )
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                FilterMenu(filters: $filters)
            }
        }
    }
}

// MARK: - Création de tag

/// Couleurs proposées à la création d'un tag (format `#rrggbb` kDrive).
enum TagPalette {
    static let colors: [String] = [
        "#e74c3c", "#e67e22", "#f1c40f", "#2ecc71", "#1abc9c",
        "#3498db", "#9b59b6", "#e84393", "#95a5a6", "#34495e",
        "#d35400", "#f39c12", "#27ae60", "#16a085", "#2980b9",
        "#8e44ad", "#c0392b", "#7f8c8d",
    ]

    /// Couleur présélectionnée à l'ouverture de la feuille.
    static let initial = colors[0]
}

/// Feuille « Nouveau tag » : nom + choix de couleur dans une palette + couleur personnalisée.
private struct CreateTagSheet: View {
    let driveId: Int
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = TagPalette.initial
    @State private var customColor: Color = Color(hex: TagPalette.initial) ?? .red
    @State private var creating = false
    @State private var errorMessage: String?

    private let service = KDriveService()

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nom") {
                    TextField("Nom du tag", text: $name)
                }
                Section("Couleur") {
                    colorGrid

                    ColorPicker("Couleur personnalisée", selection: $customColor, supportsOpacity: false)
                        .onChange(of: customColor) { _, newColor in
                            if let hex = newColor.toHex() {
                                color = hex
                            }
                        }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Nouveau tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { Task { await create() } }
                        .disabled(creating || trimmedName.isEmpty)
                }
            }
        }
    }

    private var colorGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6),
            spacing: 14
        ) {
            ForEach(TagPalette.colors, id: \.self) { hex in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        color = hex
                        if let c = Color(hex: hex) {
                            customColor = c
                        }
                    }
                } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 38, height: 38)
                        .overlay {
                            if color.lowercased() == hex.lowercased() {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.3), radius: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Couleur \(hex)")
            }
        }
        .padding(.vertical, 6)
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            try await service.createCategory(driveId: driveId, name: trimmedName, color: color)
            dismiss()
            onCreated()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
