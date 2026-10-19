import Foundation

@main struct TagIntersectionChecks {
    static func main() {
        let selection = TagIntersection([3, 1, 3])
        assert(selection.ids == [1, 3])
        assert(selection.categoryExpression == "1&3")
        assert(selection.matches([1, 2, 3]))
        assert(!selection.matches([1]))
        assert(!TagIntersection([]).matches([1, 3]))

        var state = TagIntersectionState()
        state.toggle(1); state.toggle(3)
        assert(state.isEditing && state.selectedIDs == [1, 3])
        state.finish()
        assert(!state.isEditing && state.selectedIDs == [1, 3])
        state.clear()
        assert(state.selectedIDs.isEmpty)

        let searched = TagIntersection([3, 1], query: "  vacances été\n")
        assert(searched.query == "vacances été")
        assert(searched == TagIntersection([1, 3], query: "vacances été"))
        assert(searched != selection, "Text belongs to the source identity, not to a second local filter")
        assert(TagIntersection([1, 3], query: "  \n") == selection)

        let first = Endpoint.intersectionFiles(driveId: 42, selection: searched, cursor: nil)
        let next = Endpoint.intersectionFiles(driveId: 42, selection: searched, cursor: "next&cursor")
        assert(first.path == "/3/drive/42/files/search")
        assert(next.query.filter { $0.name == "category" }.map(\.value) == ["1&3"])
        assert(next.query.first { $0.name == "query" }?.value == "vacances été")
        assert(next.query.first { $0.name == "cursor" }?.value == "next&cursor")
        assert(next.query.first { $0.name == "depth" }?.value == "unlimited")
        assert(next.query.filter { $0.name != "cursor" } == first.query)
        assert(!next.query.contains { $0.name == "query_scope" || $0.name == "category[]" })
        let categoriesOnly = Endpoint.intersectionFiles(driveId: 42, selection: selection, cursor: nil)
        assert(!categoriesOnly.query.contains { $0.name == "query" })

        // Le filtre média part en `types[]`, dans la même requête que
        // l'intersection : aucune route supplémentaire.
        let typed = Endpoint.intersectionFiles(driveId: 42, selection: searched,
                                               cursor: nil, types: ["video"])
        assert(typed.query.filter { $0.name == "types[]" }.map(\.value) == ["video"])
        assert(typed.query.first { $0.name == "category" }?.value == "1&3")
        assert(typed.query.first { $0.name == "query" }?.value == "vacances été")
        let untyped = Endpoint.intersectionFiles(driveId: 42, selection: searched, cursor: nil)
        assert(!untyped.query.contains { $0.name == "types[]" },
               "Sans type demandé, la requête reste identique à celle d'avant")

        // Les deux types structurellement différents d'un filtre média ne
        // doivent pas fusionner en une seule valeur.
        let bothTypes = Endpoint.search(driveId: 42, query: "q", directoryId: nil,
                                        cursor: nil, types: ["image", "video"])
        assert(bothTypes.query.filter { $0.name == "types[]" }.map(\.value) == ["image", "video"])
        assert(Endpoint.categoryFiles(driveId: 42, categoryId: 9, cursor: nil, types: ["dir"])
            .query.filter { $0.name == "types[]" }.map(\.value) == ["dir"])

        var components = URLComponents(string: "https://api.infomaniak.com")!
        components.path = next.path
        components.queryItems = next.query
        assert(components.percentEncodedQuery?.contains("category=1%263") == true)
        assert(URLComponents(url: components.url!, resolvingAgainstBaseURL: false)?.queryItems == next.query,
               "AND and cursor ampersands stay inside their values")

        for field in ["last_modified_at", "relevance"] {
            for direction in ["asc", "desc"] {
                let sorted = next.searchOrdering([field], order: direction)
                assert(sorted.query.first { $0.name == "order_by" }?.value == field)
                assert(sorted.query.first { $0.name == "order_for[\(field)]" }?.value == direction)
                assert(!sorted.query.contains { $0.name == "order_by[]" || $0.name == "order" })
                assert(sorted.query.first { $0.name == "cursor" }?.value == "next&cursor")
            }
        }
        for unsupported in [[], ["size"], ["updated_at"], ["relevance", "last_modified_at"]] as [[String]] {
            assert(next.searchOrdering(unsupported, order: "desc").query == next.query)
        }
        let replaced = next.searchOrdering(["relevance"], order: "desc")
            .searchOrdering(["last_modified_at"], order: "asc")
        assert(replaced.query.filter { $0.name == "order_by" }.count == 1)
        assert(!replaced.query.contains { $0.name == "order_for[relevance]" })

        let recentPage = Endpoint.lastModified(driveId: 42, cursor: nil, limit: 60)
        assert(recentPage.path == "/3/drive/42/files/last_modified")
        assert(recentPage.query.first { $0.name == "limit" }?.value == "60")
        assert(!recentPage.query.contains { $0.name == "order_by[]" || $0.name == "order" },
               "The profile keeps the endpoint's native recent order")
        let folder = Endpoint.directoryContent(driveId: 42, directoryId: 7, cursor: nil)
            .ordering(["size"], order: "desc")
        assert(folder.query.first { $0.name == "order_by[]" }?.value == "size")
        assert(folder.query.first { $0.name == "order" }?.value == "desc")
        print("Native category AND, query identity, encoding, cursor and endpoint-specific ordering checks passed")
    }
}
