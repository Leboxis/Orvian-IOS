import SwiftUI

/// Bouton et options de filtres partagés par toutes les grilles de fichiers.
///
/// Un `Menu` natif plutôt qu'un `popover` personnalisé : le popover ancré
/// dans la barre de navigation s'est révélé capricieux (ouverture aléatoire
/// au tap, fermeture au tap extérieur inopérante, probablement aggravée par
/// la présentation imbriquée du tri). Le menu système s'ouvre à chaque tap
/// et se referme au tap en dehors, sans état de présentation à gérer.
///
/// Les sélecteurs d'orientation et de type de média tiennent sur une seule
/// ligne de logos compacte. L'orientation (3 logos : portrait, paysage,
/// carré) utilise un `ControlGroup` en style `.compactMenu` : le style
/// `.menu` par défaut ne range que trois logos avec de larges marges
/// verticales, et tronque tout logo supplémentaire. Le type de média
/// (5 logos : tout, vidéos, images, dossiers, autres) dépasse la limite de
/// quatre du `ControlGroup` : il utilise donc un `Picker` en style
/// `.palette`, qui reste compact et défile horizontalement si la place
/// manque. Un tap sur un logo d'orientation ne referme pas le menu, pour
/// ajuster plusieurs critères d'affilée ; le libellé reste lu par VoiceOver
/// et la sélection se voit à la variante pleine du symbole.
struct FilterMenu: View {
    @Binding var filters: FileFilters
    @Environment(\.iPadLayout) private var iPadLayout
    @AppStorage("padFilterMenuScale") private var padFilterMenuScale = 1.2
    @ScaledMetric(relativeTo: .body) private var baseFontSize = 17
    @State private var showsPadFilters = false

    private var menuScale: CGFloat { CGFloat(min(1.5, max(1.1, padFilterMenuScale))) }

    var body: some View {
        if iPadLayout.isPad {
            Button { showsPadFilters.toggle() } label: { filterIcon }
                .popover(isPresented: $showsPadFilters) { padFilters }
                .accessibilityLabel("Filtres")
                .accessibilityHint("Trier et filtrer la liste")
        } else {
            phoneMenu
        }
    }

    // Le menu système décrit ci-dessus reste utilisé sur iPhone. Sur iPad,
    // un panneau sans sous-menu permet d'agrandir aussi les zones tactiles.
    private var phoneMenu: some View {
        Menu {
            Picker("Trier par", selection: $filters.sort) {
                ForEach(FileFilters.SortMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol)
                        .tag(mode)
                }
            }

            if filters.sort != .original {
                Picker("Ordre", selection: $filters.direction) {
                    ForEach(FileFilters.Direction.allCases) { direction in
                        Label(direction.title, systemImage: direction.symbol)
                            .tag(direction)
                    }
                }
            }

            Section("Orientation vidéo") {
                ControlGroup {
                    ForEach(FileFilters.Orientation.allCases) { orientation in
                        Button {
                            select(orientation: orientation)
                        } label: {
                            Image(systemName: orientation.symbol(selected: filters.orientation == orientation))
                        }
                        .accessibilityLabel(orientation.title)
                        .accessibilityAddTraits(filters.orientation == orientation ? .isSelected : [])
                        .menuActionDismissBehavior(.disabled)
                    }
                }
                .controlGroupStyle(.compactMenu)
                Toggle(isOn: highResolutionBinding) {
                    Label("Vidéos 4K et plus", systemImage: "4k.tv")
                }
            }

            Section("Afficher") {
                // Le libellé visible est masqué : l'en-tête de section
                // « Afficher » donne déjà le contexte, et un second intitulé
                // ajouterait une rangée vide au-dessus des logos.
                Picker(selection: mediaBinding) {
                    ForEach(FileFilters.MediaFilter.allCases) { media in
                        Label(media.title, systemImage: media.symbol(selected: filters.media == media))
                            .tag(media)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.palette)
                .accessibilityLabel("Type de média")
            }

            if filters.isActive {
                Divider()
                Button(role: .destructive) {
                    filters = FileFilters()
                } label: {
                    Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            filterIcon
        }
        .accessibilityLabel("Filtres")
        .accessibilityHint("Trier et filtrer la liste")
    }

    private var filterIcon: some View {
        Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
    }

    private var padFilters: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12 * menuScale) {
                HStack {
                    Text("Filtres").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { showsPadFilters = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(minWidth: 44 * menuScale, minHeight: 44 * menuScale)
                    }
                    .accessibilityLabel("Fermer les filtres")
                }
                Text("Trier par").foregroundStyle(.secondary)
                ForEach(FileFilters.SortMode.allCases) { mode in
                    padChoice(mode.title, symbol: mode.symbol, selected: filters.sort == mode) {
                        filters.sort = mode
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
                padChoice("Vidéos 4K et plus", symbol: "4k.tv", selected: filters.highResolutionVideosOnly) {
                    highResolutionBinding.wrappedValue.toggle()
                }
                Divider()
                Text("Afficher").foregroundStyle(.secondary)
                HStack(spacing: 4 * menuScale) {
                    ForEach(FileFilters.MediaFilter.allCases) { media in
                        padSymbol(media.title, symbol: media.symbol(selected: filters.media == media),
                                  selected: filters.media == media) { mediaBinding.wrappedValue = media }
                    }
                }
                if filters.isActive {
                    Divider()
                    Button(role: .destructive) { filters = FileFilters() } label: {
                        Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity, minHeight: 44 * menuScale, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: baseFontSize * menuScale))
            .padding(16 * menuScale)
        }
        .frame(width: min(340 * menuScale, max(280, iPadLayout.width - 32)),
               height: min(700, 560 * menuScale))
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("browser.filter.panel")
    }

    private func padChoice(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .padding(.horizontal, 10 * menuScale)
            .frame(maxWidth: .infinity, minHeight: 44 * menuScale, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 10 * menuScale))
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func padSymbol(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 44 * menuScale)
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
