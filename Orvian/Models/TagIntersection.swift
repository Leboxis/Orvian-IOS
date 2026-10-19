import Foundation

struct TagIntersection: Hashable, Sendable {
    let ids: [Int]
    let query: String

    init(_ ids: Set<Int>, query: String = "") {
        self.ids = ids.sorted()
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var categoryExpression: String { ids.map(String.init).joined(separator: "&") }
    func matches(_ membership: Set<Int>) -> Bool {
        !ids.isEmpty && Set(ids).isSubset(of: membership)
    }

}

enum TagIntersectionError: LocalizedError {
    case expressionTooLong
    var errorDescription: String? { "Trop de tags pour cette recherche. Réduisez le croisement puis réessayez." }
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
    mutating func toggleMode() {
        if isActive { clear() } else { isEditing = true }
    }
}
