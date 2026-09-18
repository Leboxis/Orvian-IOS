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
                Toggle(isOn: $filters.filesOnly) {
                    Label("Fichiers uniquement", systemImage: "doc")
                }
                .disabled(filters.media == .folders)
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
    /// réactive l'affichage des dossiers si « Fichiers uniquement » le
    /// masquait (sinon la combinaison n'afficherait rien).
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
