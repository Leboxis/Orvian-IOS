import SwiftUI

/// Bouton et panneau de filtres partagés par toutes les grilles de fichiers.
/// Le panneau reste ouvert après chaque choix afin de faciliter la combinaison
/// d'un tri et de plusieurs filtres.
struct FilterMenu: View {
    @Binding var filters: FileFilters
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            FilterPanel(filters: $filters)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Filtres")
        .accessibilityHint("Trier et filtrer la liste")
    }
}

/// Panneau de filtre compact : les sélecteurs d'orientation et de type de
/// média sont alignés horizontalement et n'affichent que leurs icônes.
private struct FilterPanel: View {
    @Binding var filters: FileFilters

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sortSection

            if filters.sort != .original {
                directionSection
            }

            iconSection(
                title: "Orientation vidéo",
                values: FileFilters.Orientation.allCases,
                symbol: \.symbol,
                isSelected: { filters.orientation == $0 },
                action: toggle
            )

            iconSection(
                title: "Afficher",
                values: FileFilters.MediaFilter.allCases,
                symbol: \.symbol,
                isSelected: { filters.media == $0 },
                action: { filters.media = $0 }
            )

            Button(role: .destructive) {
                filters = FileFilters()
            } label: {
                Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!filters.isActive)
        }
        .padding(18)
        .frame(width: 330)
    }

    private var sortSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trier par")
                .font(.subheadline.weight(.semibold))

            ForEach(FileFilters.SortMode.allCases) { mode in
                Button {
                    filters.sort = mode
                } label: {
                    rowLabel(title: mode.title, symbol: mode.symbol, selected: filters.sort == mode)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var directionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sens du tri")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(FileFilters.Direction.allCases) { direction in
                    Button {
                        filters.direction = direction
                    } label: {
                        rowLabel(title: direction.title, symbol: direction.symbol, selected: filters.direction == direction)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func iconSection<Value: Identifiable>(
        title: String,
        values: [Value],
        symbol: KeyPath<Value, String>,
        isSelected: @escaping (Value) -> Bool,
        action: @escaping (Value) -> Void
    ) -> some View where Value.ID: Hashable {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                ForEach(values) { value in
                    iconButton(
                        symbol: value[keyPath: symbol],
                        accessibilityLabel: accessibilityLabel(for: value),
                        selected: isSelected(value)
                    ) {
                        action(value)
                    }
                }
            }
        }
    }

    private func iconButton(
        symbol: String,
        accessibilityLabel: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 38)
                .foregroundStyle(selected ? .white : .primary)
                .background(
                    selected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ orientation: FileFilters.Orientation) {
        if filters.orientation == orientation {
            filters.orientation = nil
        } else {
            filters.orientation = orientation
        }
    }

    private func accessibilityLabel<Value>(for value: Value) -> String {
        switch value {
        case let orientation as FileFilters.Orientation:
            return orientation.title
        case let media as FileFilters.MediaFilter:
            return media.title
        default:
            return "Filtre"
        }
    }

    @ViewBuilder
    private func rowLabel(title: String, symbol: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
    }
}
