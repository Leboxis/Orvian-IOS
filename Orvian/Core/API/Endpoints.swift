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

// MARK: - Endpoints kDrive utilisés par le MVP
// En extension pour que `.recents(...)`, `.media(...)` etc. résolvent
// directement via la syntaxe à point partout dans le code.

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

    /// Photos et vidéos du drive (recherche typée récursive) — onglet Média.
    static func media(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/search",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "depth", value: "unlimited"),
            ] + array("types", ["image", "video"])
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
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
}
