import SwiftUI

/// Bouton et panneau de filtres partagés par toutes les grilles de fichiers.
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

/// Panneau de filtre compact, aligné sur les cartes de l'application.
/// Le choix du tri est déporté dans un sous-menu afin que le panneau principal
/// reste court, tandis que les filtres visuels restent accessibles d'un tap.
private struct FilterPanel: View {
    @Binding var filters: FileFilters

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if filters.isActive {
                Button(role: .destructive) {
                    filters = FileFilters()
                } label: {
                    Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var sortSection: some View {
        Menu {
            Picker("Trier par", selection: $filters.sort) {
                ForEach(FileFilters.SortMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol)
                        .tag(mode)
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(.secondary)
                Text("Trier par")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(filters.sort.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var directionSection: some View {
        HStack(spacing: 9) {
            Text("Ordre")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()

            HStack(spacing: 7) {
                ForEach(FileFilters.Direction.allCases) { direction in
                    iconButton(
                        symbol: direction.symbol,
                        accessibilityLabel: direction.title,
                        selected: filters.direction == direction
                    ) {
                        filters.direction = direction
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func iconSection<Value: Identifiable>(
        title: String,
        values: [Value],
        symbol: KeyPath<Value, String>,
        isSelected: @escaping (Value) -> Bool,
        action: @escaping (Value) -> Void
    ) -> some View where Value.ID: Hashable {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
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
                .frame(width: 40, height: 36)
                .foregroundStyle(selected ? .white : .primary)
                .background(
                    selected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    if !selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                }
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
}
