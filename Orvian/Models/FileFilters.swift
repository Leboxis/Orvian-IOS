import Foundation

/// Options de tri et de filtrage de la grille de fichiers.
struct FileFilters: Equatable {
    /// Ordre de tri.
    enum SortMode: String, CaseIterable, Identifiable {
        case original, date, type, size, duration

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return "Original"
            case .date: return "Date"
            case .type: return "Type"
            case .size: return "Poids"
            case .duration: return "Durée"
            }
        }

        var symbol: String {
            switch self {
            case .original: return "arrow.up.arrow.down"
            case .date: return "calendar"
            case .type: return "doc.text"
            case .size: return "externaldrive"
            case .duration: return "clock"
            }
        }
    }

    /// Sens du tri (croissant / décroissant).
    enum Direction: String, CaseIterable, Identifiable {
        case ascending, descending

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ascending: return "Croissant"
            case .descending: return "Décroissant"
            }
        }

        var symbol: String {
            switch self {
            case .ascending: return "arrow.up"
            case .descending: return "arrow.down"
            }
        }
    }

    /// Orientation des vidéos (filtres combinables entre eux).
    enum Orientation: String, CaseIterable, Identifiable {
        case portrait, landscape, square

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .portrait: return "rectangle.portrait"
            case .landscape: return "rectangle.landscape.rotate"
            case .square: return "square"
            }
        }

        var title: String {
            switch self {
            case .portrait: return "Portrait"
            case .landscape: return "Paysage"
            case .square: return "Carré"
            }
        }
    }

    /// Type de média affiché.
    enum MediaFilter: String, CaseIterable, Identifiable {
        case all, videos, images, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Tout"
            case .videos: return "Vidéos"
            case .images: return "Images"
            case .other: return "Autres"
            }
        }
    }

    var sort: SortMode = .original
    var direction: Direction = .descending
    var orientations: Set<Orientation> = []
    var media: MediaFilter = .all

    /// Vrai dès qu'un tri ou un filtre diffère du comportement par défaut.
    var isActive: Bool {
        sort != .original || !orientations.isEmpty || media != .all
    }
}