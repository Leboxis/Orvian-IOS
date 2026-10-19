import SwiftUI

/// Panneau de filtres partagé par les grilles iPhone et iPad, sans sous-menu.
/// Le popover reste ouvert pour ajuster plusieurs critères ; son contenu
/// défile lorsque la hauteur disponible ne suffit pas.
struct FilterMenu: View {
    @Binding var filters: FileFilters
    @Environment(\.iPadLayout) private var iPadLayout
    @AppStorage("padFilterMenuScale") private var padFilterMenuScale = 1.2
    @ScaledMetric(relativeTo: .body) private var baseFontSize = 14
    @State private var showsPadFilters = false

    private var menuScale: CGFloat {
        iPadLayout.isPad ? CGFloat(min(1.5, max(1.1, padFilterMenuScale))) : 1.1
    }

    var body: some View {
        Button { showsPadFilters.toggle() } label: { filterIcon }
            .popover(isPresented: $showsPadFilters) { padFilters }
            .accessibilityLabel("Filtres")
            .accessibilityHint("Trier et filtrer la liste")
    }

    private var filterIcon: some View {
        Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
    }

    private var padFilters: some View {
        ViewThatFits(in: .vertical) {
            padFilterContent
            ScrollView { padFilterContent }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: min(260 * menuScale, max(280, iPadLayout.width - 32)))
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("browser.filter.panel")
    }

    private var padFilterContent: some View {
        VStack(alignment: .leading, spacing: 4 * menuScale) {
            HStack {
                Text("Filtres").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                Spacer()
                if filters.isActive {
                    Button(role: .destructive) { filters = FileFilters() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Réinitialiser les filtres")
                }
                Button { showsPadFilters = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Fermer les filtres")
            }
            Text("Trier par").foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(FileFilters.SortMode.allCases) { mode in
                    Button {
                        filters.sort = mode
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.symbol)
                            Text(sortButtonTitle(mode))
                                .font(.system(size: baseFontSize * menuScale * 0.8))
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .padding(.vertical, 4)
                        .background(filters.sort == mode ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(filters.sort == mode ? .isSelected : [])
                }
            }
            if filters.sort != .original {
                Divider()
                HStack {
                    ForEach(FileFilters.Direction.allCases) { direction in
                        padChoice(direction.title, symbol: direction.symbol, selected: filters.direction == direction) {
                            filters.direction = direction
                        }
                    }
                }
            }
            Divider()
            Text("Orientation vidéo").foregroundStyle(.secondary)
            HStack {
                ForEach(FileFilters.Orientation.allCases) { orientation in
                    padSymbol(orientation.title, symbol: orientation.symbol(selected: filters.orientation == orientation),
                              selected: filters.orientation == orientation) { select(orientation: orientation) }
                }
            }
            Button {
                highResolutionBinding.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label("Vidéos 4K et plus", systemImage: "4k.tv")
                    if filters.highResolutionVideosOnly { Image(systemName: "checkmark") }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                .background(filters.highResolutionVideosOnly ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(filters.highResolutionVideosOnly ? .isSelected : [])
            Divider()
            Text("Afficher").foregroundStyle(.secondary)
            HStack(spacing: 4 * menuScale) {
                ForEach(FileFilters.MediaFilter.allCases) { media in
                    padSymbol(media.title, symbol: media.symbol(selected: filters.media == media),
                              selected: filters.media == media) { mediaBinding.wrappedValue = media }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: baseFontSize * menuScale))
        .padding(.horizontal, 10 * menuScale)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func sortButtonTitle(_ mode: FileFilters.SortMode) -> String {
        switch mode {
        case .original: return "Original"
        case .modifiedDate: return "Modifié"
        case .addedDate: return "Importé"
        case .type: return "Type"
        case .size: return "Taille"
        case .duration: return "Durée"
        }
    }

    private func padChoice(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .padding(.horizontal, 6 * menuScale)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 10 * menuScale))
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func padSymbol(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 10 * menuScale))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Sélection exclusive : retaper le logo actif retire l'orientation.
    /// Choisir une orientation bascule l'affichage sur les vidéos, car les
    /// orientations ne concernent ni les images, ni les dossiers, ni les
    /// autres fichiers.
    private func select(orientation: FileFilters.Orientation) {
        guard filters.orientation != orientation else {
            filters.orientation = nil
            return
        }
        filters.orientation = orientation
        if filters.media == .images || filters.media == .folders || filters.media == .other {
            filters.media = .videos
        }
    }

    /// Activer « 4K+ » bascule l'affichage sur les vidéos (même couplage que
    /// l'ancien panneau).
    private var highResolutionBinding: Binding<Bool> {
        Binding(
            get: { filters.highResolutionVideosOnly },
            set: { isOn in
                filters.highResolutionVideosOnly = isOn
                if isOn {
                    filters.media = .videos
                }
            }
        )
    }

    /// Choisir « Images », « Dossiers » ou « Autres » retire les critères
    /// vidéo devenus sans objet (orientation, 4K+). Choisir « Dossiers »
    /// retire aussi un éventuel ancien critère `filesOnly`, toujours pris
    /// en charge par le modèle mais plus proposé dans ce menu.
    private var mediaBinding: Binding<FileFilters.MediaFilter> {
        Binding(
            get: { filters.media },
            set: { media in
                filters.media = media
                if media == .images || media == .folders || media == .other {
                    filters.orientation = nil
                    filters.highResolutionVideosOnly = false
                }
                if media == .folders {
                    filters.filesOnly = false
                }
            }
        )
    }
}
