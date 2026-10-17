import Foundation

struct TagIntersection: Hashable {
    let ids: [Int]
    init(_ ids: Set<Int>) { self.ids = ids.sorted() }
    /// Official search grammar: '&' means AND, '|' means OR. URLQueryItem encodes it.
    var query: String { ids.map(String.init).joined(separator: "&") }
    func matches(_ membership: Set<Int>) -> Bool {
        !ids.isEmpty && Set(ids).isSubset(of: membership)
    }
}

struct TagIntersectionState {
    var selectedIDs: Set<Int> = []
    var isEditing = false
    var isActive: Bool { isEditing || !selectedIDs.isEmpty }
    mutating func toggle(_ id: Int) {
        isEditing = true
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    mutating func finish() { isEditing = false }
    mutating func clear() { selectedIDs = []; isEditing = false }
}
