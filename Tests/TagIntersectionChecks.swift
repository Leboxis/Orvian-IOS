import Foundation

@main struct TagIntersectionChecks {
    static func main() throws {
        let selection = TagIntersection([3, 1, 3])
        assert(selection.ids == [1, 3] && selection.query == "1&3")
        assert(selection.matches([1, 2, 3]))
        assert(!selection.matches([1]))
        assert(!TagIntersection([]).matches([1, 3]))
        var state = TagIntersectionState()
        state.toggle(1); state.toggle(3); state.finish()
        assert(!state.isEditing && state.selectedIDs == [1, 3])
        state.clear()
        assert(state.selectedIDs.isEmpty)
        let endpoint = Endpoint.intersectionFiles(driveId: 42, selection: selection, cursor: "next")
        assert(endpoint.query.first { $0.name == "category" }?.value == "1&3")
        assert(endpoint.query.first { $0.name == "cursor" }?.value == "next")
        var components = URLComponents(string: "https://example.com" + endpoint.path)!
        components.queryItems = endpoint.query
        let decoded = URLComponents(url: components.url!, resolvingAgainstBaseURL: false)!
        assert(decoded.queryItems?.first { $0.name == "category" }?.value == "1&3")
        print("Server AND query, normalization and selection state checks passed")
    }
}
