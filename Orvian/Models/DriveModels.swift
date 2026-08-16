import Foundation

/// Compte Infomaniak (`GET /1/account`).
struct InfomaniakAccount: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
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
