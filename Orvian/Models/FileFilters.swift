import Foundation

/// Options de tri et de filtrage de la grille de fichiers.
struct FileFilters: Equatable {
    /// Ordre de tri.
    enum SortMode: String, CaseIterable, Identifiable {
        case original, modifiedDate, addedDate, type, size, duration

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return "Original"
            case .modifiedDate: return "Date de modification"
            case .addedDate: return "Date d'importation"
            case .type: return "Type"
            case .size: return "Poids"
            case .duration: return "Durée"
            }
        }

        var symbol: String {
            switch self {
            case .original: return "arrow.up.arrow.down"
            case .modifiedDate: return "calendar.badge.clock"
            case .addedDate: return "calendar.badge.plus"
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

    /// Orientation des vidéos (sélection unique et exclusive).
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
    var orientation: Orientation? = nil
    var media: MediaFilter = .all

    /// Tris exprimables par l'API kDrive (`order_by[]`) : les appliquer côté
    /// serveur garantit que la pagination entière respecte le tri, pas
    /// seulement les éléments déjà chargés. `nil` pour les tris restant
    /// locaux (durée : calculée à partir des métadonnées vidéo) ou l'ordre
    /// serveur d'origine.
    var serverOrderBy: [String]? {
        switch sort {
        case .original, .duration: return nil
        case .modifiedDate: return ["last_modified_at"]
        case .addedDate: return ["added_at"]
        case .type: return ["type"]
        case .size: return ["size"]
        }
    }

    var serverOrder: String {
        direction == .descending ? "desc" : "asc"
    }

    /// Vrai dès qu'un tri ou un filtre diffère du comportement par défaut.
    var isActive: Bool {
        sort != .original || orientation != nil || media != .all
    }
}