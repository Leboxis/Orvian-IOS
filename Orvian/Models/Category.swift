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
/// JSON réel : `{"categoryId": 5, "isGeneratedByAi": false,
/// "userValidation": "CORRECT", "userId": 123, "addedAt": 1710000000}` —
/// le nom et la couleur se résolvent via `GET /2/drive/{id}/categories`.
struct FileCategory: Codable, Hashable {
    let categoryId: Int
    let isGeneratedByAi: Bool?
    let userValidation: String?
    let userId: Int?
    let addedAt: Double?
}
