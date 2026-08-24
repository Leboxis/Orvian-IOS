import Foundation

/// Options de tri et de filtrage de la grille de fichiers.
struct FileFilters: Equatable, Hashable {
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

        /// Icône affichée dans le sélecteur compact du menu de filtres.
        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .videos: return "video"
            case .images: return "photo"
            case .other: return "doc"
            }
        }
    }

    /// Palier de résolution minimal des médias affichés (images et vidéos).
    /// Le seuil s'applique au grand côté : gère indifféremment le portrait
    /// et le paysage (une vidéo 2160×3840 compte comme 4K).
    enum ResolutionTier: String, CaseIterable, Identifiable {
        case hd, fourK

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hd: return "HD"
            case .fourK: return "4K"
            }
        }

        var symbol: String {
            switch self {
            case .hd: return "aspectratio"
            case .fourK: return "4k.tv"
            }
        }

        /// Seuil minimal sur le grand côté, en pixels.
        var minimumLongEdge: Int {
            switch self {
            case .hd: return 1280
            case .fourK: return 3840
            }
        }
    }

    var sort: SortMode = .original
    var direction: Direction = .descending
    var orientation: Orientation? = nil
    var resolution: ResolutionTier? = nil
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
        sort != .original || orientation != nil || resolution != nil || media != .all
    }

    /// Applique les filtres (média, orientation vidéo, résolution, recherche)
    /// et le tri local (durée) sur une liste brute. Partagé entre la grille
    /// et la visionneuse pour garantir exactement le même ordre des éléments.
    ///
    /// Les tris pris en charge par l'API sont également appliqués localement.
    /// Cela garde le tri opérationnel sur les sources qui ne prennent pas
    /// `order_by[]` en charge (notamment les tags et les médias consultés).
    @MainActor
    func visible(_ items: [DriveFile], searchText: String, mediaMetadata: MediaMetadataStore) -> [DriveFile] {
        var result = items

        switch media {
        case .all: break
        case .videos: result = result.filter(\.isVideo)
        case .images: result = result.filter(\.isImage)
        case .other: result = result.filter { !$0.isVideo && !$0.isImage }
        }

        if let orientation {
            result = result.filter { file in
                guard file.isVideo, let info = mediaMetadata.info(for: file.id) else { return false }
                return info.orientation == orientation
            }
        }

        if let resolution {
            // Sans métadonnées résolues (sonde en cours), le média reste
            // masqué : il apparaîtra dès que ses dimensions seront connues.
            result = result.filter { file in
                guard let info = mediaMetadata.info(for: file.id) else { return false }
                return info.meets(resolution)
            }
        }

        let keywords = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        if !keywords.isEmpty {
            result = result.filter { $0.matchesSearchKeywords(keywords) }
        }

        result = sorted(result, mediaMetadata: mediaMetadata)

        return result
    }

    @MainActor
    private func sorted(
        _ files: [DriveFile],
        mediaMetadata: MediaMetadataStore
    ) -> [DriveFile] {
        guard sort != .original else { return files }

        return files.sorted { lhs, rhs in
            switch sort {
            case .original:
                return false
            case .modifiedDate:
                return ordered(lhs.lastModifiedAt ?? -.infinity, rhs.lastModifiedAt ?? -.infinity, lhs: lhs, rhs: rhs)
            case .addedDate:
                return ordered(lhs.addedAt ?? -.infinity, rhs.addedAt ?? -.infinity, lhs: lhs, rhs: rhs)
            case .type:
                return ordered(lhs.fileKind.rawValue, rhs.fileKind.rawValue, lhs: lhs, rhs: rhs)
            case .size:
                return ordered(lhs.size ?? -1, rhs.size ?? -1, lhs: lhs, rhs: rhs)
            case .duration:
                let lhsDuration = mediaMetadata.info(for: lhs.id)?.duration ?? -1
                let rhsDuration = mediaMetadata.info(for: rhs.id)?.duration ?? -1
                return ordered(lhsDuration, rhsDuration, lhs: lhs, rhs: rhs)
            }
        }
    }

    private func ordered<Value: Comparable>(
        _ lhsValue: Value,
        _ rhsValue: Value,
        lhs: DriveFile,
        rhs: DriveFile
    ) -> Bool {
        if lhsValue == rhsValue {
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder == .orderedSame {
                return lhs.id < rhs.id
            }
            return nameOrder == .orderedAscending
        }
        return direction == .descending ? lhsValue > rhsValue : lhsValue < rhsValue
    }
}
