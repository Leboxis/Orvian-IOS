import Foundation

/// Listes paginées, fiches fichiers et comptage.
extension KDriveService {
    /// Une entrée du flux `/files/activities` contient le fichier dans la clé
    /// `file`; elle n'est pas elle-même un `DriveFile`.
    private struct ActivityEntry: Decodable {
        let file: DriveFile?
    }

    private static let browsableOrderingFields: Set<String> = [
        "added_at", "last_modified_at", "mime_type", "name",
        "revised_at", "size", "type", "updated_at",
    ]

    func page(
        _ source: FileSource,
        driveId: Int,
        cursor: String?,
        orderBy: [String]? = nil,
        order: String = "asc",
        forceNetwork: Bool = false
    ) async throws -> CursorPage<DriveFile> {
        // `forceNetwork` : pull-to-refresh, changement de tri et rafraîchissements
        // post-mutation exigent l'état courant du serveur. Sinon, la réponse
        // peut être revalidée par le cache HTTP (ETag → 304 sans re-téléchargement).
        let cachePolicy: URLRequest.CachePolicy = forceNetwork
            ? .reloadIgnoringLocalCacheData
            : .useProtocolCachePolicy
        let endpoint: Endpoint
        switch source {
        case let .directory(directoryId):
            endpoint = safeOrdering(
                .directoryContent(driveId: driveId, directoryId: directoryId, cursor: cursor),
                requested: orderBy,
                order: order,
                allowed: Self.browsableOrderingFields
            )
        case let .favorites(limit):
            endpoint = safeOrdering(
                .favorites(driveId: driveId, cursor: cursor, limit: limit),
                requested: orderBy,
                order: order,
                allowed: Self.browsableOrderingFields
            )
        case let .recents(limit):
            // 1) Priorité /files/last_modified (fichiers modifiés/uploadés récemment sur le drive).
            // Une liste vide est un résultat valide : on ne bascule vers le
            // repli que sur une erreur propre à ce endpoint (indisponible
            // pour le compte, réponse illisible) — `isFallbackCandidate`.
            // Une panne réseau, un 401 ou un 429 concerne tous les endpoints
            // de la cascade : l'ancien comportement tentait les quatre et
            // multipliait les requêtes vouées à l'échec à chaque chargement.
            do {
                return try await api.get(
                    CursorPage<DriveFile>.self,
                    safeOrdering(
                        .lastModified(driveId: driveId, cursor: cursor, limit: limit),
                        requested: orderBy,
                        order: order,
                        allowed: ["last_modified_at"],
                        aliases: ["updated_at": "last_modified_at"]
                    ),
                    cachePolicy: cachePolicy
                )
            } catch let error as APIError where error.isFallbackCandidate {
                // 2) Fallback /files/recents
                do {
                    return try await api.get(
                        CursorPage<DriveFile>.self,
                        safeOrdering(
                            .recents(driveId: driveId, cursor: cursor, limit: limit),
                            requested: orderBy,
                            order: order,
                            allowed: ["updated_at"],
                            aliases: ["last_modified_at": "updated_at"]
                        ),
                        cachePolicy: cachePolicy
                    )
                } catch let error as APIError where error.isFallbackCandidate {
                    // 3) Fallback /files/activities
                    do {
                        let activityPage = try await api.get(
                            CursorPage<ActivityEntry>.self,
                            safeOrdering(
                                .activities(driveId: driveId, cursor: cursor, limit: limit),
                                requested: orderBy,
                                order: order,
                                allowed: ["created_at"],
                                aliases: ["last_modified_at": "created_at", "updated_at": "created_at"]
                            ),
                            cachePolicy: cachePolicy
                        )
                        var seen: Set<Int> = []
                        let files = (activityPage.data ?? [])
                            .compactMap(\.file)
                            .filter { seen.insert($0.id).inserted }
                        return CursorPage<DriveFile>(
                            result: activityPage.result,
                            data: files,
                            cursor: activityPage.cursor,
                            hasMore: activityPage.hasMore
                        )
                    } catch let error as APIError where error.isFallbackCandidate {
                        // 4) Dernier recours : recherche globale
                        endpoint = safeOrdering(
                            .search(driveId: driveId, query: "", directoryId: nil, cursor: cursor, limit: limit),
                            requested: orderBy,
                            order: order,
                            allowed: ["last_modified_at"],
                            aliases: ["updated_at": "last_modified_at"]
                        )
                    }
                }
            }
        case let .category(categoryId):
            endpoint = safeOrdering(
                .categoryFiles(driveId: driveId, categoryId: categoryId, cursor: cursor),
                requested: orderBy,
                order: order,
                allowed: ["last_modified_at"],
                aliases: ["updated_at": "last_modified_at"]
            )
        case .trash:
            endpoint = safeOrdering(
                .trashContent(driveId: driveId, cursor: cursor),
                requested: orderBy,
                order: order,
                allowed: Self.browsableOrderingFields
            )
        case let .search(query, directoryId):
            endpoint = safeOrdering(
                .search(driveId: driveId, query: query, directoryId: directoryId, cursor: cursor),
                requested: orderBy,
                order: order,
                allowed: ["last_modified_at"],
                aliases: ["updated_at": "last_modified_at"]
            )
        }
        return try await api.get(CursorPage<DriveFile>.self, endpoint, cachePolicy: cachePolicy)
    }

    /// Chaque endpoint kDrive possède sa propre liste de valeurs `order_by`.
    /// Un tri non pris en charge reste local dans `FileFilters` au lieu de
    /// transformer une page valide en erreur HTTP 400.
    private func safeOrdering(
        _ endpoint: Endpoint,
        requested: [String]?,
        order: String,
        allowed: Set<String>,
        aliases: [String: String] = [:]
    ) -> Endpoint {
        guard let requested, !requested.isEmpty else { return endpoint }
        let resolved = requested.compactMap { field -> String? in
            if let alias = aliases[field], allowed.contains(alias) {
                return alias
            }
            return allowed.contains(field) ? field : nil
        }
        guard resolved.count == requested.count else { return endpoint }
        return endpoint.ordering(resolved, order: order)
    }

    /// Fiche complète d'un fichier (v3). Les listes (notamment la recherche
    /// par tag) ne renvoient pas toujours `categories` : cette fiche est la
    /// source fiable pour connaître les tags réellement appliqués.
    func fileInfo(driveId: Int, fileId: Int) async throws -> DriveFile {
        guard let file = try await api.get(DataResponse<DriveFile>.self, .fileInfo(driveId: driveId, fileId: fileId)).data else {
            throw APIError.invalidResponse
        }
        return file
    }

    /// Nombre total d'éléments d'un dossier (fichiers + dossiers), via
    /// l'endpoint `count` dédié : les listes paginées n'exposent pas de total.
    func directoryCount(driveId: Int, directoryId: Int) async throws -> Int {
        let wrapper = try await api.get(DataResponse<DirectoryCount>.self, .directoryCount(driveId: driveId, directoryId: directoryId))
        guard let count = wrapper.data?.count else { throw APIError.invalidResponse }
        return count
    }
}
