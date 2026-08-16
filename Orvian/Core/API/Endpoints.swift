import Foundation

/// Requête API décrit de façon déclarative.
struct Endpoint {
    var path: String
    var query: [URLQueryItem] = []

    /// Item répété façon PHP `types[]=…` (l'API kDrive attend ce format).
    static func array(_ name: String, _ values: [String]) -> [URLQueryItem] {
        values.map { URLQueryItem(name: "\(name)[]", value: $0) }
    }
}

// MARK: - Endpoints kDrive utilisés par l'app
// En extension pour que `.favorites(...)`, `.categoryFiles(...)` etc.
// résolvent directement via la syntaxe à point partout dans le code.

extension Endpoint {
    /// Comptes accessibles avec le token courant.
    static var accounts: Endpoint { Endpoint(path: "/1/account") }

    /// Drives d'un compte.
    static func drives(accountId: Int) -> Endpoint {
        Endpoint(path: "/2/drive", query: [URLQueryItem(name: "account_id", value: String(accountId))])
    }

    /// Contenu d'un dossier (dossiers en premier, puis fichiers, par nom).
    static func directoryContent(driveId: Int, directoryId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/\(directoryId)/files",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "order_by[]", value: "type"),
                URLQueryItem(name: "order_by[]", value: "name"),
                URLQueryItem(name: "order", value: "asc"),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Fichiers récents du drive.
    static func recents(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/recents",
            query: [URLQueryItem(name: "limit", value: String(limit))]
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Favoris du drive.
    static func favorites(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/favorites",
            query: [URLQueryItem(name: "limit", value: String(limit))]
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Fichiers d'une catégorie (recherche par catégorie, récursive).
    /// NB : le endpoint search n'accepte pas `order_by[]=name` — tri par pertinence.
    static func categoryFiles(driveId: Int, categoryId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/search",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "category", value: String(categoryId)),
                URLQueryItem(name: "depth", value: "unlimited"),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Catégories du drive.
    static func categories(driveId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/categories")
    }

    /// Miniature carrée (10…400 px).
    static func thumbnail(driveId: Int, fileId: Int, pixels: Int) -> Endpoint {
        Endpoint(
            path: "/2/drive/\(driveId)/files/\(fileId)/thumbnail",
            query: [
                URLQueryItem(name: "width", value: String(pixels)),
                URLQueryItem(name: "height", value: String(pixels)),
            ]
        )
    }

    /// URL temporaire publique (streaming AVPlayer / image haute résolution).
    static func temporaryURL(driveId: Int, fileId: Int, duration: Int = 3600) -> Endpoint {
        Endpoint(
            path: "/2/drive/\(driveId)/files/\(fileId)/temporary_url",
            query: [URLQueryItem(name: "duration", value: String(duration))]
        )
    }

    /// Favori : POST pour ajouter, DELETE pour retirer (même chemin).
    static func favorite(driveId: Int, fileId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)/favorite")
    }

    /// Créer un dossier : POST JSON `{"name": …}` (v3).
    static func createFolder(driveId: Int, directoryId: Int) -> Endpoint {
        Endpoint(path: "/3/drive/\(driveId)/files/\(directoryId)/directory")
    }

    /// Upload d'un fichier : POST corps brut (`application/octet-stream`).
    /// `conflict=rename` : le serveur renomme si le nom existe déjà.
    static func upload(driveId: Int, directoryId: Int, fileName: String, totalSize: Int) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/upload",
            query: [
                URLQueryItem(name: "directory_id", value: String(directoryId)),
                URLQueryItem(name: "file_name", value: fileName),
                URLQueryItem(name: "total_size", value: String(totalSize)),
                URLQueryItem(name: "conflict", value: "rename"),
            ]
        )
    }
}
