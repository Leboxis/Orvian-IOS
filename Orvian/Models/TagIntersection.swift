import Foundation

struct TagIntersection: Hashable, Sendable {
    let ids: [Int]
    init(_ ids: Set<Int>) { self.ids = ids.sorted() }
    func matches(_ membership: Set<Int>) -> Bool {
        !ids.isEmpty && Set(ids).isSubset(of: membership)
    }

    /// Filter the item's own memberships, never its parent's. Missing metadata
    /// is resolved only when necessary, with at most four requests in flight.
    /// Failures propagate so they cannot be mistaken for an empty intersection.
    func filterPage<Item: Sendable>(
        _ items: [Item],
        membership: @escaping @Sendable (Item) -> Set<Int>?,
        resolve: @escaping @Sendable (Item) async throws -> Item
    ) async throws -> [Item] {
        guard !ids.isEmpty else { return [] }
        try Task.checkCancellation()
        var resolved = items
        let missing = items.indices.filter { membership(items[$0]) == nil }
        for start in stride(from: 0, to: missing.count, by: 4) {
            try Task.checkCancellation()
            let batch = missing[start..<min(start + 4, missing.count)]
            let values = try await withThrowingTaskGroup(of: (Int, Item).self) { group in
                for index in batch {
                    let item = items[index]
                    group.addTask { (index, try await resolve(item)) }
                }
                var values: [(Int, Item)] = []
                for try await value in group { values.append(value) }
                return values
            }
            for (index, item) in values { resolved[index] = item }
        }
        try Task.checkCancellation()
        let required = Set(ids)
        return try resolved.filter { item in
            guard let ownTags = membership(item) else { throw TagIntersectionError.missingMembership }
            return required.isSubset(of: ownTags)
        }
    }
}

enum TagIntersectionError: LocalizedError {
    case missingMembership
    var errorDescription: String? { "Impossible de vérifier les tags de certains éléments. Réessayez le chargement." }
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
