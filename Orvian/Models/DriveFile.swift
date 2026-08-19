import Foundation

/// Fichier ou dossier kDrive.
///
/// Unifie les schémas `FileV3` / `DirectoryV3` de l'API v3 : les dossiers
/// reviennent avec des champs plus pauvres que les fichiers, tout est donc
/// optionnel sauf l'essentiel.
struct DriveFile: Codable, Identifiable, Hashable {
    let id: Int
    var name: String
    /// "dir" ou "file"
    let type: String
    let size: Int?
    let mimeType: String?
    /// Type fonctionnel renvoyé par l'API : image, video, audio, dir, pdf, text,
    /// spreadsheet, presentation, archive, code, font, unknown…
    let extensionType: String?
    var isFavorite: Bool?
    let parentId: Int?
    let path: String?
    /// Couleur hexadécimale (#rrggbb) des dossiers, définie côté kDrive.
    let color: String?
    /// Catégories (tags) du fichier — renvoyées uniquement avec `with=categories`.
    var categories: [FileCategory]?
    /// Timestamps Unix (secondes)
    let addedAt: Double?
    let lastModifiedAt: Double?

    var isDirectory: Bool { type == "dir" }
    var isImage: Bool { fileKind == .image }
    var isVideo: Bool { fileKind == .video }

    var fileKind: FileKind {
        FileKind(extensionType: extensionType, mimeType: mimeType, fileName: name, isDirectory: isDirectory)
    }

    /// Vérifie si le nom du fichier contient l'ensemble des mots-clés recherchés.
    func matchesSearchKeywords(_ keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return true }
        return keywords.allSatisfy { word in
            name.localizedStandardContains(word)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, size, path
        case mimeType
        case extensionType
        case isFavorite
        case parentId
        case color
        case categories
        case addedAt
        case lastModifiedAt
    }
}

/// Page curseur renvoyée par les endpoints v3 (`NavigatorResponse`).
struct CursorPage<T: Decodable>: Decodable {
    let result: String?
    let data: [T]?
    let cursor: String?
    let hasMore: Bool?

    init(result: String? = "success", data: [T]?, cursor: String? = nil, hasMore: Bool? = nil) {
        self.result = result
        self.data = data
        self.cursor = cursor
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case result, data, cursor
        case hasMore = "has_more"
    }
}

/// Réponse simple `{ result, data }`.
struct DataResponse<T: Decodable>: Decodable {
    let result: String?
    let data: T?
}

/// `GET /2/drive/{id}/files/{id}/temporary_url`
struct TemporaryURL: Decodable {
    let temporaryUrl: String

    enum CodingKeys: String, CodingKey {
        case temporaryUrl = "temporary_url"
    }
}
