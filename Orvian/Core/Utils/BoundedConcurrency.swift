import Foundation

/// Exécute `operation` sur chaque élément avec une concurrence bornée.
///
/// Un seul emplacement pour le motif « plusieurs tâches en même temps, mais
/// pas trop » (uploads en lots, mutations de sélection, application de tags)
/// auparavant recopié à cinq endroits.
///
/// Sémantique conservée :
/// - découpage par lots de `concurrency` : le lot suivant démarre quand le
///   lot courant est terminé (pas de fenêtre glissante) ;
/// - les résultats suivent l'ordre d'entrée, quel que soit l'ordre
///   d'achèvement des tâches ;
/// - l'annulation n'interrompt pas la fonction : chaque `operation` gère
///   `Task.isCancelled` à sa façon (souvent en renvoyant nil), et l'appelant
///   peut consulter `Task.isCancelled` après l'appel.
///
/// - Returns: un résultat par élément, dans l'ordre d'entrée.
func mapBounded<T: Sendable, R: Sendable>(
    _ items: [T],
    concurrency: Int,
    operation: @escaping @Sendable (T) async -> R
) async -> [R] {
    guard !items.isEmpty, concurrency > 0 else { return [] }

    var results = [R?](repeating: nil, count: items.count)
    var start = 0
    while start < items.count {
        let end = min(start + concurrency, items.count)
        await withTaskGroup(of: (Int, R).self) { group in
            for index in start..<end {
                let item = items[index]
                group.addTask {
                    return (index, await operation(item))
                }
            }
            for await (index, result) in group {
                results[index] = result
            }
        }
        start = end
    }
    return results.compactMap { $0 }
}
