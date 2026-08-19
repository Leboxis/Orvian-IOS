import Foundation

/// Catégorie kDrive (`GET /2/drive/{id}/categories`).
struct Category: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    /// Couleur hexadécimale, p.ex. « #f1c40f ».
    let color: String?
    let isPredefined: Bool?
    let userUses: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case isPredefined = "is_predefined"
        case userUses = "user_uses"
    }
}

/// Catégorie attachée à un fichier (`FileCategory` de l'API v3) :
/// objet plat renvoyé dans les listes de fichiers avec `with=categories`.
/// Le décodage accepte les variantes observées selon les endpoints :
/// camelCase v3 (`categoryId`), snake_case (`category_id`), objet enveloppé
/// (`category: {id, …}`) ou catégorie complète (`id`). Un élément illisible
/// ne fait plus échouer toute la réponse (`categoryId = -1`, ignoré par
/// l'interface). Le nom et la couleur se résolvent via
/// `GET /2/drive/{id}/categories`.
struct FileCategory: Codable, Hashable {
    let categoryId: Int
    let isGeneratedByAi: Bool?
    let userValidation: String?
    let userId: Int?
    let addedAt: Double?

    enum CodingKeys: String, CodingKey {
        case categoryId
        case categoryIdSnake = "category_id"
        case wrappedCategory = "category"
        case plainId = "id"
        case isGeneratedByAi
        case isGeneratedByAiSnake = "is_generated_by_ai"
        case userValidation
        case userValidationSnake = "user_validation"
        case userId
        case userIdSnake = "user_id"
        case addedAt
        case addedAtSnake = "added_at"
    }

    private struct WrappedCategory: Decodable {
        let id: Int
    }

    init(
        categoryId: Int,
        isGeneratedByAi: Bool? = nil,
        userValidation: String? = nil,
        userId: Int? = nil,
        addedAt: Double? = nil
    ) {
        self.categoryId = categoryId
        self.isGeneratedByAi = isGeneratedByAi
        self.userValidation = userValidation
        self.userId = userId
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categoryId = (try? c.decode(Int.self, forKey: .categoryId))
            ?? (try? c.decode(Int.self, forKey: .categoryIdSnake))
            ?? (try? c.decode(WrappedCategory.self, forKey: .wrappedCategory))?.id
            ?? (try? c.decode(Int.self, forKey: .plainId))
            ?? -1
        isGeneratedByAi = (try? c.decode(Bool.self, forKey: .isGeneratedByAi))
            ?? (try? c.decode(Bool.self, forKey: .isGeneratedByAiSnake))
        userValidation = (try? c.decode(String.self, forKey: .userValidation))
            ?? (try? c.decode(String.self, forKey: .userValidationSnake))
        userId = (try? c.decode(Int.self, forKey: .userId))
            ?? (try? c.decode(Int.self, forKey: .userIdSnake))
        addedAt = (try? c.decode(Double.self, forKey: .addedAt))
            ?? (try? c.decode(Double.self, forKey: .addedAtSnake))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(categoryId, forKey: .categoryId)
        try c.encodeIfPresent(isGeneratedByAi, forKey: .isGeneratedByAi)
        try c.encodeIfPresent(userValidation, forKey: .userValidation)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encodeIfPresent(addedAt, forKey: .addedAt)
    }
}
