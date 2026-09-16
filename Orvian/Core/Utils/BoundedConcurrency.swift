import Foundation

/// Exécute `operation` sur chaque élément avec une concurrence bornée.
///
/// Un seul emplacement pour le motif « plusieurs tâches en même temps, mais
/// pas trop » (uploads en lots, mutations de sélection, application de tags)
/// auparavant recopié à cinq endroits.
///
/// Une place libérée accueille immédiatement l'élément suivant. Les résultats
/// conservent l'ordre d'entrée. Comme auparavant, chaque opération reçoit
/// l'annulation et produit son résultat (un résultat par élément).
func mapBounded<T: Sendable, R: Sendable>(
    _ items: [T],
    concurrency: Int,
    operation: @escaping @Sendable (T) async -> R
) async -> [R] {
    guard !items.isEmpty, concurrency > 0 else { return [] }

    var results = [R?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, R).self) { group in
        var nextIndex = 0
        while nextIndex < min(concurrency, items.count) {
            let index = nextIndex
            let item = items[index]
            group.addTask { (index, await operation(item)) }
            nextIndex += 1
        }
        while let (index, result) = await group.next() {
            results[index] = result
            if nextIndex < items.count {
                let index = nextIndex
            let item = items[index]
            group.addTask { (index, await operation(item)) }
                nextIndex += 1
            }
        }
    }
    return results.compactMap { $0 }
}
