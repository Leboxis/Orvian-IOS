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
    /// `with=is_favorite,categories` : ces champs ne sont renvoyés que sur
    /// demande explicite (cf. app kDrive officielle).
    static func directoryContent(driveId: Int, directoryId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/\(directoryId)/files",
            query: [
                URLQueryItem(name: "with", value: "is_favorite,categories"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "order_by[]", value: "type"),
                URLQueryItem(name: "order_by[]", value: "name"),
                URLQueryItem(name: "order", value: "asc"),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Fichiers récemment modifiés / uploadés (/3/drive/{id}/files/last_modified).
    static func lastModified(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/last_modified",
            query: [
                URLQueryItem(name: "with", value: "is_favorite,categories"),
                URLQueryItem(name: "limit", value: String(limit)),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Fichiers récents du drive (/3/drive/{id}/files/recents).
    static func recents(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/recents",
            query: [
                URLQueryItem(name: "with", value: "is_favorite,categories"),
                URLQueryItem(name: "limit", value: String(limit)),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Flux d'activités récentes (/3/drive/{id}/files/activities).
    static func activities(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/activities",
            query: [
                URLQueryItem(name: "with", value: "is_favorite,categories"),
                URLQueryItem(name: "limit", value: String(limit)),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Favoris du drive.
    static func favorites(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/favorites",
            query: [
                URLQueryItem(name: "with", value: "is_favorite,categories"),
                URLQueryItem(name: "limit", value: String(limit)),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Fichiers d'une catégorie (recherche par catégorie, récursive).
    /// NB : le endpoint search n'accepte pas `order_by[]=name` — tri par pertinence.
    static func categoryFiles(driveId: Int, categoryId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/files/search",
            query: [
                URLQueryItem(name: "with", value: "is_favorite,categories"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "category", value: String(categoryId)),
                URLQueryItem(name: "depth", value: "unlimited"),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Recherche récursive de fichiers dans un dossier (ou tout le drive) et ses sous-dossiers.
    static func search(driveId: Int, query: String, directoryId: Int?, cursor: String?, limit: Int = 60) -> Endpoint {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "with", value: "is_favorite,categories"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "depth", value: "unlimited"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: trimmed))
        }
        if let directoryId {
            queryItems.append(URLQueryItem(name: "directory_id", value: String(directoryId)))
        }
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return Endpoint(path: "/3/drive/\(driveId)/files/search", query: queryItems)
    }


    /// Contenu de la corbeille (v3, pagination curseur).
    static func trashContent(driveId: Int, cursor: String?, limit: Int = 60) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/trash",
            query: [
                URLQueryItem(name: "with", value: "is_favorite,categories"),
                URLQueryItem(name: "limit", value: String(limit)),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        )
    }

    /// Catégories du drive : GET pour lister, POST pour en créer une.
    static func categories(driveId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/categories")
    }

    /// Catégorie individuelle : PUT pour modifier/renommer, DELETE pour supprimer (v2).
    static func category(driveId: Int, categoryId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/categories/\(categoryId)")
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

    /// Miniature d'un fichier corbeillé (même format que `.thumbnail`).
    static func trashedThumbnail(driveId: Int, fileId: Int, pixels: Int) -> Endpoint {
        Endpoint(
            path: "/2/drive/\(driveId)/trash/\(fileId)/thumbnail",
            query: [
                URLQueryItem(name: "width", value: String(pixels)),
                URLQueryItem(name: "height", value: String(pixels)),
            ]
        )
    }

    /// Restaurer un fichier depuis la corbeille : POST JSON
    /// `{"destination_directory_id": …}` (v2).
    static func restore(driveId: Int, fileId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/trash/\(fileId)/restore")
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

    /// Catégorie (tag) d'un fichier : POST pour appliquer, DELETE pour retirer (v2).
    static func fileCategory(driveId: Int, fileId: Int, categoryId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)/categories/\(categoryId)")
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

    /// Supprimer un fichier (le déplacer dans la corbeille).
    static func trash(driveId: Int, fileId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)")
    }

    /// Supprimer définitivement un fichier/dossier de la corbeille (v2).
    static func permanentDelete(driveId: Int, fileId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/trash/\(fileId)")
    }

    /// Renommer un fichier ou dossier.
    static func rename(driveId: Int, fileId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)/rename")
    }

    /// Déplace un fichier ou dossier vers un dossier de destination (v3).
    static func move(driveId: Int, fileId: Int, destinationDirectoryId: Int) -> Endpoint {
        Endpoint(path: "/3/drive/\(driveId)/files/\(fileId)/move/\(destinationDirectoryId)")
    }
}
