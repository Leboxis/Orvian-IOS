import SwiftUI

/// Menu compact de filtres : tri, sens du tri, orientation vidéo et type de
/// média. Chaque choix est appliqué instantanément (aucun bouton de validation).
struct FilterMenu: View {
    @Binding var filters: FileFilters

    var body: some View {
        Menu {
            sortSection
            if filters.sort != .original {
                directionSection
            }
            orientationSection
            mediaSection
            resetSection
        } label: {
            Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filtres")
        .accessibilityHint("Trier et filtrer la liste")
    }

    private var sortSection: some View {
        Section("Trier par") {
            ForEach(FileFilters.SortMode.allCases) { mode in
                Button {
                    filters.sort = mode
                } label: {
                    rowLabel(title: mode.title, symbol: mode.symbol, selected: filters.sort == mode)
                }
            }
        }
    }

    private var directionSection: some View {
        Section("Sens du tri") {
            ForEach(FileFilters.Direction.allCases) { direction in
                Button {
                    filters.direction = direction
                } label: {
                    rowLabel(title: direction.title, symbol: direction.symbol, selected: filters.direction == direction)
                }
            }
        }
    }

    private var orientationSection: some View {
        Section("Orientation vidéo") {
            ForEach(FileFilters.Orientation.allCases) { orientation in
                Button {
                    toggle(orientation)
                } label: {
                    rowLabel(
                        title: orientation.title,
                        symbol: orientation.symbol,
                        selected: filters.orientations.contains(orientation)
                    )
                }
            }
        }
    }

    private var mediaSection: some View {
        Section("Afficher") {
            ForEach(FileFilters.MediaFilter.allCases) { media in
                Button {
                    filters.media = media
                } label: {
                    rowLabel(title: media.title, symbol: nil, selected: filters.media == media)
                }
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                filters = FileFilters()
            } label: {
                Label("Réinitialiser", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func toggle(_ orientation: FileFilters.Orientation) {
        if filters.orientations.contains(orientation) {
            filters.orientations.remove(orientation)
        } else {
            filters.orientations.insert(orientation)
        }
    }

    /// Ligne du menu : coche si sélectionné, sinon icône d'illustration.
    @ViewBuilder
    private func rowLabel(title: String, symbol: String?, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else if let symbol {
            Label(title, systemImage: symbol)
        } else {
            Text(title)
        }
    }
}
