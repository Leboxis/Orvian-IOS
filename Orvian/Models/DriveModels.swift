import Foundation

/// Compte Infomaniak (`GET /1/account`).
struct InfomaniakAccount: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
}

/// Taille du contenu courant, hors versions (`GET /2/drive/{id}/files/{id}/sizes`).
/// Le champ `storage_size` représente aussi les versions et n’est pas le poids affiché.
struct DirectorySize: Decodable, Sendable {
    let size: Int

    private enum CodingKeys: String, CodingKey { case size }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decode(Int.self, forKey: .size)
        guard size >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .size, in: container,
                                                   debugDescription: "A directory size cannot be negative")
        }
    }
}

/// Drive kDrive (`GET /2/drive`).
struct Drive: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let size: Int?
    let usedSize: Int?
    let accountId: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case usedSize = "used_size"
        case accountId = "account_id"
    }
}
