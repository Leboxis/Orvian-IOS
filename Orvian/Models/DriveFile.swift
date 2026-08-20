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
    var color: String?
    /// Catégories (tags) du fichier — renvoyées uniquement avec `with=categories`.
    var categories: [FileCategory]?
    /// Timestamps Unix (secondes)
    var addedAt: Double?
    var lastModifiedAt: Double?

    var isDirectory: Bool { type == "dir" }
    var isImage: Bool { fileKind == .image }
    var isVideo: Bool { fileKind == .video }

    /// Fichier texte brut (extension .txt) : seul ce format est garanti
    /// encodé en texte simple et ouvrable dans la visionneuse de texte.
    var isPlainText: Bool {
        (name as NSString).pathExtension.lowercased() == "txt"
    }

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
        case mimeTypeSnake = "mime_type"
        case extensionType
        case extensionTypeSnake = "extension_type"
        case isFavorite
        case isFavoriteSnake = "is_favorite"
        case parentId
        case parentIdSnake = "parent_id"
        case color
        case categories
        case addedAt
        case addedAtSnake = "added_at"
        case lastModifiedAt
        case lastModifiedAtSnake = "last_modified_at"
    }
}

extension DriveFile {
    /// Le décodage accepte indifféremment camelCase (v3) et snake_case (v2) :
    /// les listes de fichiers kDrive renvoient encore des clés snake_case
    /// (`mime_type`, `extension_type`, `parent_id`, `added_at`…), certains
    /// endpoints récents les renvoient en camelCase. Sans cette tolérance,
    /// ces champs restaient nuls et tous les tris/filtres basés dessus
    /// (dates, type, médias, favoris) cessaient de fonctionner.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        mimeType = Self.decode(c, camel: .mimeType, snake: .mimeTypeSnake)
        extensionType = Self.decode(c, camel: .extensionType, snake: .extensionTypeSnake)
        isFavorite = Self.decode(c, camel: .isFavorite, snake: .isFavoriteSnake)
        parentId = Self.decode(c, camel: .parentId, snake: .parentIdSnake)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        categories = try c.decodeIfPresent([FileCategory].self, forKey: .categories)
        addedAt = Self.decode(c, camel: .addedAt, snake: .addedAtSnake)
        lastModifiedAt = Self.decode(c, camel: .lastModifiedAt, snake: .lastModifiedAtSnake)
    }

    /// Décode une valeur en essayant d'abord la clé camelCase, puis la clé
    /// snake_case. Retourne nil si les deux sont absentes ou nulles.
    private static func decode<T: Decodable>(
        _ c: KeyedDecodingContainer<CodingKeys>,
        camel: CodingKeys,
        snake: CodingKeys
    ) -> T? {
        if let value = try? c.decode(T.self, forKey: camel) {
            return value
        }
        return try? c.decode(T.self, forKey: snake)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(mimeType, forKey: .mimeTypeSnake)
        try c.encodeIfPresent(extensionType, forKey: .extensionTypeSnake)
        try c.encodeIfPresent(isFavorite, forKey: .isFavoriteSnake)
        try c.encodeIfPresent(parentId, forKey: .parentIdSnake)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(categories, forKey: .categories)
        try c.encodeIfPresent(addedAt, forKey: .addedAtSnake)
        try c.encodeIfPresent(lastModifiedAt, forKey: .lastModifiedAtSnake)
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
