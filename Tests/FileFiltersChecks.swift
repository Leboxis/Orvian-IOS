import Foundation

/// Vérifie le tri de `FileFilters` et sa combinaison avec la recherche.
///
/// Compile le vrai `FileFilters.swift`, le vrai `FileSource+Ordering.swift`
/// et les vrais modèles (`DriveFile`, `FileKind`) ; seuls les types dépendant
/// d'AVFoundation sont remplacés par des doubles.
@main
struct FileFiltersChecks {
    static func main() {
        checkOrderingCapabilities()
        checkServerHonoredOrderIsLeftAlone()
        checkLocalSortFillsInForIgnoredOrder()
        checkOriginalAndDurationSorts()
        checkDirectionAndTieBreak()
        checkSearchThenSort()
        print("FileFilters ordering, search and source gating checks passed")
    }

    // MARK: - Capacités de la source

    /// Le contrat partagé avec `KDriveService.safeOrdering` : ces endpoints
    /// n'acceptent que la date de modification, tout autre tri doit donc
    /// retomber sur le tri local.
    static func checkOrderingCapabilities() {
        for source in [FileSource.search(query: "a", directoryId: nil),
                       FileSource.category(1),
                       FileSource.recents()] {
            precondition(source.supportedServerOrdering == ["updated_at", "last_modified_at"],
                         "\(source) n'accepte que la date de modification")
        }
        for source in [FileSource.directory(1), .favorites, .trash] {
            for field in ["updated_at", "added_at", "type", "size"] {
                precondition(source.supportedServerOrdering.contains(field),
                             "\(source) doit accepter \(field)")
            }
            precondition(!source.isServerFiltered, "\(source) n'est pas filtrée par le serveur")
        }
        precondition(FileSource.search(query: "q", directoryId: nil).isServerFiltered,
                     "La recherche serveur est déjà filtrée : relancer les mots-clés en local la masquerait")
        precondition(!FileSource.category(1).isServerFiltered,
                     "Les tags reposent sur un filtrage local, pas sur les règles de pertinence")
    }

    // MARK: - Tri local conditionnel

    static func checkServerHonoredOrderIsLeftAlone() {
        // L'ordre reçu du serveur doit être préservé tel quel : re-trier en
        // local ferait doublon et pourrait dériver du comparateur serveur.
        let items = [file(1, "b", size: 10), file(2, "a", size: 30), file(3, "c", size: 20)]
        let filters = FileFilters(sort: .size, direction: .descending)

        for source in [FileSource.directory(1), FileSource.favorites, FileSource.trash] {
            let result = filters.visible(items, searchText: "", metadata: .init(), source: source)
            precondition(result.map(\.id) == [1, 2, 3],
                         "L'ordre serveur de \(source) doit être préservé, obtenu \(result.map(\.id))")
        }

        // Alias : `updated_at` est traduit en `last_modified_at` par les
        // endpoints de recherche et de tags, donc aussi honoré côté serveur.
        let dated = [file(1, "b", updatedAt: 100), file(2, "a", updatedAt: 300), file(3, "c", updatedAt: 200)]
        let byDate = FileFilters(sort: .modifiedDate, direction: .descending)
        for source in [FileSource.search(query: "q", directoryId: nil), FileSource.category(1)] {
            let result = byDate.visible(dated, searchText: "", metadata: .init(), source: source)
            precondition(result.map(\.id) == [1, 2, 3],
                         "L'alias updated_at est honoré par \(source) : pas de tri local")
        }
    }

    static func checkLocalSortFillsInForIgnoredOrder() {
        // Régression du commit « Skip local sort when server-side ordering is
        // available » : sans tri local, Taille, Type et Date d'importation
        // n'avaient aucun effet sur la recherche, les tags ni les récents.
        let items = [file(1, "b", size: 10), file(2, "a", size: 30), file(3, "c", size: 20)]
        let filters = FileFilters(sort: .size, direction: .descending)

        for source in [FileSource.search(query: "q", directoryId: nil),
                       FileSource.category(1),
                       FileSource.recents()] {
            let result = filters.visible(items, searchText: "", metadata: .init(), source: source)
            precondition(result.map(\.id) == [2, 3, 1],
                         "Tri local attendu pour \(source), obtenu \(result.map(\.id))")
        }

        // Source inconnue (nil) : on trie, faute de preuve que le serveur l'a fait.
        let unknown = filters.visible(items, searchText: "", metadata: .init(), source: nil)
        precondition(unknown.map(\.id) == [2, 3, 1], "Une source inconnue doit trier en local")

        let byType = FileFilters(sort: .type, direction: .ascending)
        let typed = [
            file(1, "doc.pdf", extensionType: "pdf"),
            file(2, "clip.mp4", extensionType: "video"),
            file(3, "note.txt", extensionType: "text"),
        ]
        let typedResult = byType.visible(typed, searchText: "", metadata: .init(),
                                         source: FileSource.recents())
        // rawValue croissants : "pdf" < "text" < "video".
        precondition(typedResult.map(\.id) == [1, 3, 2],
                     "Tri par type sur les récents, obtenu \(typedResult.map(\.id))")
    }

    static func checkOriginalAndDurationSorts() {
        let items = [file(1, "b", size: 10), file(2, "a", size: 30), file(3, "c", size: 20)]
        let untouched = FileFilters().visible(items, searchText: "", metadata: .init(),
                                              source: FileSource.search(query: "q", directoryId: nil))
        precondition(untouched.map(\.id) == [1, 2, 3], "L'ordre d'origine ne doit jamais être trié")

        // La durée n'a pas d'équivalent serveur : toujours triée en local,
        // même sur une source dont l'endpoint honore les autres ordres.
        let metadata = VideoMetadataSnapshot(infos: [
            1: VideoMetadataInfo(duration: 30, orientation: .landscape, maximumDimension: 1920),
            2: VideoMetadataInfo(duration: 10, orientation: .landscape, maximumDimension: 1920),
            3: VideoMetadataInfo(duration: 20, orientation: .landscape, maximumDimension: 1920),
        ])
        let byDuration = FileFilters(sort: .duration, direction: .ascending)
        let result = byDuration.visible(items, searchText: "", metadata: metadata,
                                        source: FileSource.directory(1))
        precondition(result.map(\.id) == [2, 3, 1],
                     "Tri par durée attendu, obtenu \(result.map(\.id))")

        // Vidéo sans métadonnée : durées inconnues (-1) placées avant les
        // durées connues, départagées entre elles par le nom ("b" avant "c").
        let partial = VideoMetadataSnapshot(infos: [
            2: VideoMetadataInfo(duration: 10, orientation: .landscape, maximumDimension: 1920),
        ])
        let unknownDuration = byDuration.visible(items, searchText: "", metadata: partial,
                                                 source: FileSource.directory(1))
        precondition(unknownDuration.map(\.id) == [1, 3, 2],
                     "Durée inconnue placée avant les durées connues, obtenu \(unknownDuration.map(\.id))")
    }

    static func checkDirectionAndTieBreak() {
        let items = [file(1, "b", size: 10), file(2, "a", size: 30), file(3, "c", size: 20)]
        let source = FileSource.search(query: "q", directoryId: nil)

        let ascending = FileFilters(sort: .size, direction: .ascending)
            .visible(items, searchText: "", metadata: .init(), source: source)
        precondition(ascending.map(\.id) == [1, 3, 2], "Ordre croissant attendu, obtenu \(ascending.map(\.id))")

        // Ex æquo : départage par le nom, dans l'ordre Finder, tous sens.
        let ties = [file(1, "fichier 10"), file(2, "fichier 2"), file(3, "fichier 1")]
        let tieDescending = FileFilters(sort: .size, direction: .descending)
            .visible(ties, searchText: "", metadata: .init(), source: source)
        precondition(tieDescending.map(\.id) == [3, 2, 1],
                     "Départage par nom attendu, obtenu \(tieDescending.map(\.id))")
    }

    // MARK: - Recherche + tri

    /// La recherche filtre **d'abord**, le tri s'applique ensuite aux
    /// résultats : trier avant de filtrer ferait apparaître des éléments
    /// masqués ou décalerait les positions.
    static func checkSearchThenSort() {
        let items = [
            file(1, "rapport zeta", size: 10),
            file(2, "rapport alpha", size: 30),
            file(3, "photo beta", size: 20),
            file(4, "rapport gamma", size: 40),
        ]
        // Source dont l'endpoint ignore l'ordre : le tri local s'exerce
        // réellement sur le sous-ensemble filtré.
        let source = FileSource.search(query: "rapport", directoryId: nil)
        let filters = FileFilters(sort: .size, direction: .descending)

        let result = filters.visible(items, searchText: "rapport",
                                     metadata: .init(), source: source)
        precondition(result.map(\.id) == [4, 2, 1],
                     "Filtrer puis trier attendu, obtenu \(result.map(\.id))")

        // Recherche locale sur les Favoris (source qui honore l'ordre) :
        // le filtre s'applique, l'ordre serveur est préservé.
        let favorites = filters.visible(items, searchText: "rapport",
                                        metadata: .init(), source: FileSource.favorites)
        precondition(favorites.map(\.id) == [1, 2, 4],
                     "Filtrage local sans re-tri attendu, obtenu \(favorites.map(\.id))")

        // Aucun résultat : la liste filtrée est vide, le tri ne réintroduit rien.
        let empty = filters.visible(items, searchText: "introuvable",
                                    metadata: .init(), source: source)
        precondition(empty.isEmpty, "Une recherche sans correspondance doit rester vide")
    }

    // MARK: - Fixtures

    private static func file(
        _ id: Int,
        _ name: String,
        type: String = "file",
        size: Int? = nil,
        extensionType: String? = nil,
        addedAt: Double? = nil,
        lastModifiedAt: Double? = nil,
        updatedAt: Double? = nil
    ) -> DriveFile {
        DriveFile(
            id: id,
            name: name,
            type: type,
            size: size,
            mimeType: nil,
            extensionType: extensionType,
            fileExtension: nil,
            isFavorite: nil,
            parentId: nil,
            path: nil,
            color: nil,
            categories: nil,
            addedAt: addedAt,
            lastModifiedAt: lastModifiedAt,
            updatedAt: updatedAt
        )
    }
}
