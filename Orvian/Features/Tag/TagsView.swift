import SwiftUI
import UniformTypeIdentifiers

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
    @Binding var padNavigation: IPadTagNavigation
    /// Visibilité de la colonne de gauche (bouton de masquage de l'en-tête).
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var crossState: TagIntersectionState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.iPadLayout) private var iPadLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.phoneBottomChromeHeight) private var phoneBottomChromeHeight

    @State private var categories: [Category] = []
    @State private var orderedCategories: [Category] = []
    @State private var isLoading = false
    /// Évite d'afficher provisoirement « (0) » avant la première réponse API.
    @State private var hasLoadedCategories = false
    @State private var errorMessage: String?
    @State private var operationErrorMessage: String?
    /// Affichage des catégories : grille (défaut) ou liste.
    @AppStorage("tagsLayout") private var phoneLayout = CategoryLayout.grid
    @AppStorage("padTagsLayout") private var padLayout = CategoryLayout.list
    private var layout: CategoryLayout {
        get { iPadLayout.isPad ? padLayout : phoneLayout }
        nonmutating set { if iPadLayout.isPad { padLayout = newValue } else { phoneLayout = newValue } }
    }
    private var usesTagColumns: Bool { iPadLayout.isPad && iPadLayout.width >= 700 && !dynamicTypeSize.isAccessibilitySize }
    private enum CrossRoute: Hashable { case results }
    private var isSelectingTags: Bool {
        crossState.isEditing || (!iPadLayout.isPad && crossState.isActive)
    }
    /// Nombre de colonnes de la grille, partagé avec l'éditeur de tags.
    @AppStorage("tagGridColumns") private var tagGridColumns = 2
    @State private var showCreateSheet = false

    @State private var tagToRename: Category?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    @State private var tagToDelete: Category?
    @State private var showDeleteConfirm = false

    /// Mode réordonnancement : bouton crayon, glisser-déposer des cartes,
    /// ordre mémorisé par drive via `TagOrderStore`.
    @State private var isReordering = false
    /// Tag actuellement saisi pendant le glisser-déposer.
    @State private var draggedCategory: Category?
    /// Ordre personnalisé (IDs) chargé depuis `TagOrderStore` ; nil → ordre du serveur.
    @State private var customOrder: [Int]?

    private let service = KDriveService()

    var body: some View {
        Group {
            if usesTagColumns {
                padNavigationView
            } else {
                phoneNavigation
            }
        }
            .onChange(of: categories, initial: true) { _, _ in
            updateOrder()
            if hasLoadedCategories, let id = padNavigation.categoryID,
               !categories.contains(where: { $0.id == id }) {
                padNavigation.select(nil)
            }
        }
        .onChange(of: customOrder) { _, _ in updateOrder() }
        .onChange(of: crossState.selectedIDs) { _, _ in padNavigation.folders = [] }
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

    private var phoneNavigation: some View {
        NavigationStack(path: $path) {
            Group {
                if iPadLayout.isPad {
                    root.toolbar { categoryToolbar }
                } else {
                    phoneCatalogue
                }
            }
                .navigationDestination(for: CrossRoute.self) { _ in
                    intersectionResults.modifier(TagDestinationNavigationBar(isPhone: !iPadLayout.isPad))
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
                    .modifier(TagDestinationNavigationBar(isPhone: !iPadLayout.isPad))
                }
                .navigationDestination(for: DriveFile.self) { directory in
                    DirectoryView(
                        directory: directory,
                        driveId: driveId,
                        crumbs: trail,
                        router: router,
                        onNavigateAncestor: { depth in
                            let retained = depth + 1
                            if path.count > retained {
                                Motion.withoutNavigationAnimation { path.removeLast(path.count - retained) }
                            }
                        },
                        onOpenFolder: { folder in
                            push(folder)
                        }
                    )
                    .modifier(TagDestinationNavigationBar(isPhone: !iPadLayout.isPad))
                }
        }
        .transaction { $0.disablesAnimations = true }
    }

    private var phoneCatalogue: some View {
        VStack(spacing: 0) {
            phoneCatalogueHeader
            catalogueContent
        }
        .background {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var phoneCatalogueHeader: some View {
        // Same title, action order and icon language as the iPad header,
        // without the sidebar toggle or a second navigation bar.
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    phoneCatalogueTitle
                    if crossState.isActive { phoneResultsButton }
                }
                VStack(alignment: .leading, spacing: 0) {
                    phoneCatalogueTitle
                    if crossState.isActive { phoneResultsButton }
                }
            }
            HStack(spacing: 0) {
                Button {
                    layout = layout == .grid ? .list : .grid
                } label: {
                    Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(layout == .grid ? "Afficher les tags en liste" : "Afficher les tags en grille")
                crossButton
                    .foregroundStyle(crossState.isActive ? Color.accentColor : .primary)
                Button {
                    guard !crossState.isActive else { return }
                    crossState.isEditing = false
                    isReordering.toggle()
                } label: {
                    Image(systemName: isReordering ? "checkmark.circle" : "arrow.up.arrow.down")
                        .frame(width: 44, height: 44)
                        .foregroundStyle(isReordering ? Color.accentColor : .primary)
                        .background(isReordering ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                }
                .accessibilityLabel(isReordering ? "Terminer le réarrangement" : "Réarranger les tags")
                .accessibilityValue(isReordering ? "Réarrangement activé" : "Réarrangement désactivé")
                .accessibilityAddTraits(isReordering ? .isSelected : [])
                .disabled(crossState.isActive)
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Nouveau tag")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.title2.weight(.medium))
        .tint(.primary)
        .buttonStyle(TagCataloguePressStyle())
        .padding(.horizontal, DS.gridMargin)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var phoneCatalogueTitle: some View {
        Text(hasLoadedCategories ? "Tags (\(categories.count))" : "Tags")
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var phoneResultsButton: some View {
        Button {
            path.append(CrossRoute.results)
            trail.append("Croisement de tags")
        } label: {
            Text("Résultats (\(crossState.selectedIDs.count))")
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
        .foregroundStyle(Color.accentColor)
        .disabled(crossState.selectedIDs.isEmpty)
        .accessibilityLabel("Voir le croisement de \(crossState.selectedIDs.count) tags")
        .accessibilityHint("Le bouton Retour permet de modifier les tags sélectionnés.")
    }

    @ToolbarContentBuilder
    private var categoryToolbar: some ToolbarContent {
        if iPadLayout.isPad {
            ToolbarItemGroup(placement: .topBarTrailing) {
                crossButton
                Button {
                    withAnimation(Motion.animation(.snappy(duration: 0.25))) {
                        layout = layout == .grid ? .list : .grid
                    }
                } label: {
                    Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(layout == .grid ? "Afficher en liste" : "Afficher en grille")
                Button {
                    guard !crossState.isActive else { return }
                    crossState.isEditing = false
                    isReordering.toggle()
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel(isReordering ? "Terminer le réarrangement" : "Réarranger les tags")
                .disabled(crossState.isActive)
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Nouveau tag")
            }
        }
    }

    private var padNavigationView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            padCategoryList
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            NavigationStack(path: $padNavigation.folders) {
                Group {
                    if crossState.isActive {
                        intersectionResults
                    } else if let category = selectedCategory {
                        CategoryFilesView(category: category, driveId: driveId, router: router,
                                          onOpenFolder: { padNavigation.folders.append($0) })
                            .id(category.id)
                    } else {
                        EmptyStateView(symbol: "tag", title: "Vos fichiers par tag",
                                       message: "Choisissez un tag pour consulter ses fichiers.")
                    }
                }
                .navigationDestination(for: DriveFile.self) { directory in
                    let index = padNavigation.folders.firstIndex { $0.id == directory.id }
                    let names = index.map { Array(padNavigation.folders[...$0].map(\.name)) } ?? [directory.name]
                    DirectoryView(directory: directory, driveId: driveId,
                                   crumbs: [crossState.isActive ? "Croisement de tags" : (selectedCategory?.name ?? "Tags")] + names, router: router,
                                   onNavigateAncestor: { depth in
                                       padNavigation.folders = Array(padNavigation.folders.prefix(depth))
                                   },
                                  onOpenFolder: { padNavigation.folders.append($0) })
                }
            }
            .transaction { $0.disablesAnimations = true }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var selectedCategory: Category? {
        categories.first { $0.id == padNavigation.categoryID }
    }

    private var crossButton: some View {
        Button {
            isReordering = false
            padNavigation.folders = []
            if iPadLayout.isPad {
                let wasActive = crossState.isActive
                crossState.toggleMode()
                if !wasActive { padNavigation.select(nil) }
                if wasActive && !usesTagColumns { path = NavigationPath(); trail = [] }
            } else {
                crossState.toggleMode()
            }
        } label: {
            Image(systemName: crossState.isActive ? "checklist.checked" : "checklist")
                .frame(width: 44, height: 44)
                .background(crossState.isActive ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
        }
        .accessibilityLabel(iPadLayout.isPad
            ? (crossState.isActive ? "Arrêter le croisement des tags" : "Croiser plusieurs tags")
            : (crossState.isActive ? "Désactiver la sélection multiple des tags" : "Activer la sélection multiple des tags"))
        .accessibilityIdentifier("tags.cross")
        .accessibilityValue(crossState.isActive ? "Sélection multiple activée" : "Sélection multiple désactivée")
        .accessibilityHint(!iPadLayout.isPad && crossState.isActive ? "Désactive le croisement et efface les tags sélectionnés." : "")
        .accessibilityAddTraits(crossState.isActive ? .isSelected : [])
        .tint(crossState.isActive ? .accentColor : .primary)
    }

    @ViewBuilder private var crossSummary: some View {
        if crossState.isActive && iPadLayout.isPad && !usesTagColumns {
            NavigationLink("Résultats", value: CrossRoute.results)
        }
    }

    private var intersectionResults: some View {
        TagIntersectionView(driveId: driveId, router: router, selection: TagIntersection(crossState.selectedIDs),
                            categories: categories, hasLoadedCategories: hasLoadedCategories,
                            onOpenFolder: { folder in
            if usesTagColumns { padNavigation.folders.append(folder) } else { push(folder) }
        })
        .toolbar {
            if iPadLayout.isPad && !usesTagColumns {
                ToolbarItem(placement: .topBarLeading) { crossButton }
            }
        }
    }

    private var categorySelection: Binding<Int?> {
        Binding(get: { crossState.isEditing ? nil : padNavigation.categoryID }, set: {
            guard !crossState.isEditing else { return }
            crossState.clear(); padNavigation.select($0)
        })
    }

    @ViewBuilder
    private var padCategoryList: some View {
        VStack(spacing: 0) {
            // Un seul en-tête, sans seconde barre de navigation au-dessus.
            PadSidebarHeader(title: Text(hasLoadedCategories ? "Tags (\(categories.count))" : "Tags"),
                             columnVisibility: $columnVisibility, centersActions: true) {
                Button { layout = layout == .grid ? .list : .grid } label: {
                    Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(layout == .grid ? "Afficher les tags en liste" : "Afficher les tags en grille")
                crossButton
                Button {
                    crossState.isEditing = false
                    isReordering.toggle()
                } label: {
                    Image(systemName: isReordering ? "checkmark.circle" : "arrow.up.arrow.down")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isReordering ? "Terminer le réarrangement" : "Réarranger les tags")
                .disabled(crossState.isActive)
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Nouveau tag")
            }

            crossSummary
            if categories.isEmpty || layout == .grid {
                root
            } else {
                List(selection: categorySelection) {
                    ForEach(orderedCategories) { category in
                        if crossState.isEditing {
                            Button { crossState.toggle(category.id) } label: {
                                CategoryRow(category: category, inSidebar: true, isSelecting: true,
                                            isSelected: crossState.selectedIDs.contains(category.id))
                            }
                            .listRowBackground(Color.clear)
                            .accessibilityAddTraits(crossState.selectedIDs.contains(category.id) ? .isSelected : [])
                        } else if isReordering {
                            reorderCell(for: category, inSidebar: true)
                        } else {
                            NavigationLink(value: category.id) {
                                CategoryRow(category: category, inSidebar: true)
                            }
                            .contextMenu { tagContextMenu(for: category) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle(tagNavigationTitle)
                .refreshable { await load(force: true) }
                .scrollContentBackground(.hidden)
                // Couleur de page de l'app : le matériau de barre latérale rend
                // ≈ `secondarySystemGroupedBackground`, la couleur de *carte*, donc
                // la colonne lisait comme une carte géante collée au détail.
                // Aucune réserve basse : la barre d'onglets native de l'iPad
                // insère déjà son espace. `DS.floatingBarInset` appartient à la
                // barre flottante iPhone et laissait une bande vide sous la liste.
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
    }

    private var root: some View {
        VStack(spacing: 8) {
            if !usesTagColumns { crossSummary }
            catalogueContent
        }
    }

    private var catalogueContent: some View {
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
                    message: "Vos tags apparaîtront ici une fois créés."
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
        let title = Text("Tags")
        guard hasLoadedCategories else { return title }
        return title + Text(" (\(categories.count))")
            .font(.system(size: 10, weight: .medium))
    }

    /// Ordre d'affichage : ordre personnalisé si l'utilisateur l'a défini
    /// (bouton crayon), sinon l'ordre renvoyé par le serveur. Les tags créés
    /// après un réarrangement sont ajoutés à la fin.
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
                            catalogueGridCard(for: category,
                                              isSelecting: isSelectingTags,
                                              isSelected: crossState.selectedIDs.contains(category.id))
                        }
                        .modifier(TagCataloguePressFeedback(isPhone: !iPadLayout.isPad))
                        .accessibilityAddTraits(crossState.selectedIDs.contains(category.id) ? .isSelected : [])
                        .contextMenu {
                            tagContextMenu(for: category)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.gridMargin)
            .padding(.top, 6)
            .padding(.bottom, DS.contentBottomInset + (iPadLayout.isPad ? 0 : phoneBottomChromeHeight))
            // Bloc centré et borné en largeur : sur iPad, deux colonnes
            // étirées sur 1 000 pt rendaient les cartes illisibles.
            .frame(maxWidth: DS.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            await load(force: true)
        }
    }
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: DS.gridSpacing), count: dynamicTypeSize.isAccessibilitySize ? 1 : min(3, max(2, tagGridColumns)))
    }

    @ViewBuilder
    private var list: some View {
        if iPadLayout.isPad {
            cardList
        } else {
            phoneList
        }
    }

    private var phoneList: some View {
        List {
            ForEach(orderedCategories) { category in
                Group {
                    if isReordering {
                        reorderCell(for: category, inSidebar: true)
                    } else {
                        Button {
                            open(category)
                        } label: {
                            CategoryRow(category: category, inSidebar: true,
                                        isSelecting: isSelectingTags,
                                        isSelected: crossState.selectedIDs.contains(category.id),
                                        showsSelectionIndicator: false)
                        }
                        .buttonStyle(TagCataloguePressStyle())
                        .accessibilityAddTraits(crossState.selectedIDs.contains(category.id) ? .isSelected : [])
                        .contextMenu { tagContextMenu(for: category) }
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
                .listRowInsets(EdgeInsets(top: 0, leading: DS.gridMargin, bottom: 0, trailing: DS.gridMargin))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, DS.contentBottomInset + phoneBottomChromeHeight, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await load(force: true) }
    }

    private var cardList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(orderedCategories) { category in
                    if isReordering {
                        reorderCell(for: category)
                    } else {
                        Button {
                            open(category)
                        } label: {
                            CategoryRow(category: category, isSelecting: crossState.isEditing,
                                        isSelected: crossState.selectedIDs.contains(category.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(crossState.selectedIDs.contains(category.id) ? .isSelected : [])
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
            .padding(.bottom, DS.contentBottomInset)
            .frame(maxWidth: DS.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            await load(force: true)
        }
    }

    private func catalogueGridCard(for category: Category, isSelecting: Bool = false, isSelected: Bool = false) -> some View {
        TagGridCard(category: category, verticalPadding: iPadLayout.isPad ? 12 : 10,
                    backgroundOpacity: iPadLayout.isPad && colorScheme == .dark ? 0.2 : 1,
                    isSelecting: isSelecting, isSelected: isSelected,
                    showsSelectionIndicator: iPadLayout.isPad)
            .background {
                if !iPadLayout.isPad || colorScheme == .light {
                    // Keep the native surface beneath the translucent selection tint.
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
    }

    /// Cellule du mode réarrangement : même présentation que le mode courant
    /// (grille ou liste), bordure pour signaler le mode actif, et
    /// glisser-déposer natif (`onDrag`/`onDrop`) pour déplacer le tag.
    /// `inSidebar` force la forme ligne : la barre latérale est une liste,
    /// y injecter des cartes de grille cassait sa présentation.
    @ViewBuilder
    private func reorderCell(for category: Category, inSidebar: Bool = false) -> some View {
        Group {
            if layout == .grid && !inSidebar {
                catalogueGridCard(for: category)
            } else {
                CategoryRow(category: category, inSidebar: inSidebar)
            }
        }
        .padding(.horizontal, inSidebar ? 10 : 0)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if orderedCategories.first?.id != category.id {
                Button("Monter") { moveCategory(category, by: -1) }
            }
            if orderedCategories.last?.id != category.id {
                Button("Descendre") { moveCategory(category, by: 1) }
            }
        }
        .opacity(draggedCategory?.id == category.id ? 0.55 : 1)
        .onDrag {
            draggedCategory = category
            return NSItemProvider(object: category.name as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: TagReorderDropDelegate(
            item: category,
            dragged: $draggedCategory,
            move: reorderCategory,
            finish: { draggedCategory = nil }
        ))
    }

    private func updateOrder() {
        orderedCategories = TagOrderStore.sorted(categories, order: customOrder)
    }

    private func moveCategory(_ category: Category, by delta: Int) {
        guard let index = orderedCategories.firstIndex(where: { $0.id == category.id }),
              orderedCategories.indices.contains(index + delta) else { return }
        reorderCategory(category, to: orderedCategories[index + delta])
    }

    /// Déplace `source` à la position de `target` dans l'ordre affiché, avec
    /// animation, puis persiste le nouvel ordre complet.
    private func reorderCategory(_ source: Category, to target: Category) {
        var ordered = orderedCategories
        guard let fromIndex = ordered.firstIndex(where: { $0.id == source.id }),
              let toIndex = ordered.firstIndex(where: { $0.id == target.id }),
              fromIndex != toIndex
        else { return }
        withAnimation(Motion.animation(.snappy(duration: 0.25))) {
            ordered.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
            orderedCategories = ordered
            customOrder = ordered.map(\.id)
        }
        TagOrderStore.save(ordered.map(\.id), driveId: driveId)
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
        if isSelectingTags { crossState.toggle(category.id); return }
        crossState.clear()
        if usesTagColumns { padNavigation.select(category.id); return }
        path.append(category)
        trail.append(category.name)
    }

    @MainActor
    private func push(_ folder: DriveFile) {
        Motion.withoutNavigationAnimation {
            path.append(folder)
            trail.append(folder.name)
        }
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

private struct TagCataloguePressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.6 : 1)
    }
}

private struct TagCataloguePressFeedback: ViewModifier {
    let isPhone: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPhone {
            content.buttonStyle(TagCataloguePressStyle())
        } else {
            content.buttonStyle(.plain)
        }
    }
}

/// The phone catalogue owns its header; pushed browsers keep native back/actions.
private struct TagDestinationNavigationBar: ViewModifier {
    let isPhone: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPhone {
            content.toolbar(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

private struct CategoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let category: Category
    /// Ligne de la barre latérale iPad : la liste native fournit déjà le fond,
    /// le liseré et la sélection. La carte et le chevron de la version iPhone
    /// y doublaient le relief et annonçaient une pile qui n'existe pas.
    var inSidebar = false
    var isSelecting = false
    var isSelected = false
    var showsSelectionIndicator = true

    private var tint: Color {
        Color(hex: category.color) ?? .accentColor
    }

    var body: some View {
        if inSidebar {
            // La liste native de la barre latérale fournit déjà le fond et le
            // liseré : encadrer la ligne d'une carte y doublait le relief.
            // Une liste ne pose qu'une hauteur minimale : c'est ce rembourrage
            // vertical qui règle l'air entre les lignes de la colonne.
            row.padding(.vertical, 12)
                .background(isSelected ? Color.accentColor.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if !showsSelectionIndicator && isSelected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                    }
                }
        } else {
            row
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 1.5)
                }
                // Ombre de pastille en ligne (DS.inlineShadow) : sur une liste
                // qui défile, une ombre large force une passe de flou par
                // cellule à chaque image. Le rayon minimal du système de
                // design garde le relief sans ce surcoût par carte.
                .shadow(color: DS.inlineShadow, radius: DS.inlineShadowRadius, x: 0, y: DS.inlineShadowY)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .font(.system(size: inSidebar ? 13 : 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: inSidebar ? 28 : 38, height: inSidebar ? 28 : 38)
                .background(tint, in: RoundedRectangle(cornerRadius: inSidebar ? 8 : 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if let uses = category.userUses, uses > 0 {
                    Text("\(uses) élément\(uses > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsSelectionIndicator {
                ZStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .opacity(isSelecting ? 1 : 0)
                    if !inSidebar && !isSelecting {
                        // Le chevron annonce une pile poussée : la sélection de la
                        // barre latérale n'en a pas.
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 24)
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Carte de catégorie pour les grilles de tags.
/// Employée aussi dans l'éditeur de tags afin de conserver une présentation
/// parfaitement cohérente entre l'onglet dédié et le menu d'un fichier.
struct TagGridCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let category: Category
    /// Variante resserrée des éditeurs de tags : icône et textes réduits,
    /// compteur d'usage masqué, pour en afficher davantage à l'écran.
    var compact = false
    var verticalPadding: CGFloat = 12
    var backgroundOpacity: Double = 1
    var isSelecting = false
    var isSelected = false
    var showsSelectionIndicator = true

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
                CardNameLayout {
                    Text(category.name)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : (compact ? 1 : 2))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                }
                if !compact, let uses = category.userUses, uses > 0 {
                    Text("\(uses) élément\(uses > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 8 : verticalPadding)
        .background((isSelected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground))
            .opacity(isSelected ? 0.08 : backgroundOpacity), in: RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08 * backgroundOpacity),
                              lineWidth: isSelected ? 1.5 : 0.5)
        }
        // Même raison que `CategoryRow` : le flou d'ombre se joue par carte à
        // chaque image du défilement, le liseré suffit à détacher la carte.
        .shadow(color: DS.inlineShadow.opacity(backgroundOpacity), radius: DS.inlineShadowRadius, x: 0, y: DS.inlineShadowY)
        .overlay(alignment: .topTrailing) {
            if isSelecting && showsSelectionIndicator {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(6)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
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

    @State private var browserPath: [DriveFile] = []

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
    }

    var body: some View {
        FavoritesView(driveId: driveId, router: router, path: $browserPath,
                      source: .category(category.id), title: category.name,
                      ownsNavigation: false, onOpenFolder: onOpenFolder)
            .environment(\.fileBrowserScope, .tag)
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
    @Environment(\.iPadLayout) private var iPadLayout
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
            columns: iPadLayout.isPad
                ? Array(repeating: GridItem(.flexible(), spacing: 14), count: 6)
                : [GridItem(.adaptive(minimum: 44), spacing: 14)],
            spacing: 14
        ) {
            ForEach(TagPalette.colors, id: \.self) { hex in
                Button {
                    withAnimation(Motion.animation(.snappy(duration: 0.2))) {
                        color = hex
                        if let c = Color(hex: hex) {
                            customColor = c
                        }
                    }
                } label: {
                    if iPadLayout.isPad {
                        colorSwatch(hex)
                    } else {
                        colorSwatch(hex)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Couleur \(hex)")
            }
        }
        .padding(.vertical, 6)
    }

    private func colorSwatch(_ hex: String) -> some View {
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

/// Dépose d'une carte de tag pendant le réarrangement : dès que la carte
/// saisie survole une autre carte, l'ordre est échangé (glissement continu,
/// sans bouton). Le relâchement hors cible ne change rien.
private struct TagReorderDropDelegate: DropDelegate {
    let item: Category
    @Binding var dragged: Category?
    let move: (_ source: Category, _ target: Category) -> Void
    let finish: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged.id != item.id else { return }
        move(dragged, item)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        finish()
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil
    }
}
