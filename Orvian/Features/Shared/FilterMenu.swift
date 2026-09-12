import SwiftUI

/// Bouton et options de filtres partagés par toutes les grilles de fichiers.
///
/// Un `Menu` natif plutôt qu'un `popover` personnalisé : le popover ancré
/// dans la barre de navigation s'est révélé capricieux (ouverture aléatoire
/// au tap, fermeture au tap extérieur inopérante, probablement aggravée par
/// la présentation imbriquée du tri). Le menu système s'ouvre à chaque tap
/// et se referme au tap en dehors, sans état de présentation à gérer.
struct FilterMenu: View {
    @Binding var filters: FileFilters

    var body: some View {
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
                ForEach(FileFilters.Orientation.allCases) { orientation in
                    Toggle(isOn: orientationBinding(for: orientation)) {
                        Label(orientation.title, systemImage: orientation.symbol)
                    }
                }
                Toggle(isOn: highResolutionBinding) {
                    Label("Vidéos 4K et plus", systemImage: "4k.tv")
                }
            }

            Section("Afficher") {
                Picker("Afficher", selection: mediaBinding) {
                    ForEach(FileFilters.MediaFilter.allCases) { media in
                        Label(media.title, systemImage: media.symbol)
                            .tag(media)
                    }
                }
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
            Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filtres")
        .accessibilityHint("Trier et filtrer la liste")
    }

    /// Sélection exclusive : une seule orientation à la fois, retaper la coche
    /// la retire. Choisir une orientation bascule l'affichage sur les vidéos.
    private func orientationBinding(for orientation: FileFilters.Orientation) -> Binding<Bool> {
        Binding(
            get: { filters.orientation == orientation },
            set: { isOn in
                if isOn {
                    filters.orientation = orientation
                    if filters.media == .images || filters.media == .other {
                        filters.media = .videos
                    }
                } else if filters.orientation == orientation {
                    filters.orientation = nil
                }
            }
        )
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

    /// Choisir « Images » ou « Autres » retire les critères vidéo devenus sans
    /// objet (orientation, 4K+).
    private var mediaBinding: Binding<FileFilters.MediaFilter> {
        Binding(
            get: { filters.media },
            set: { media in
                filters.media = media
                if media == .images || media == .other {
                    filters.orientation = nil
                    filters.highResolutionVideosOnly = false
                }
            }
        )
    }
}
