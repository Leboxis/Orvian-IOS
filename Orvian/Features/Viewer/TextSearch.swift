import Foundation

/// Recherche UTF-16 hors du MainActor, compatible avec les plages de UITextView.
enum TextSearch {
    static let maximumMatches = 2_000

    static func ranges(query: String, in document: String) async -> [NSRange] {
        guard !query.isEmpty, !Task.isCancelled else { return [] }
        let worker = Task.detached(priority: .userInitiated) { () -> [NSRange] in
            let text = document as NSString
            var matches: [NSRange] = []
            var remaining = NSRange(location: 0, length: text.length)
            let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            while remaining.location < text.length {
                guard !Task.isCancelled else { return [] }
                let found = text.range(of: query, options: options, range: remaining)
                if found.location == NSNotFound { break }
                matches.append(found)
                if matches.count >= maximumMatches { break }
                let next = found.location + max(found.length, 1)
                if next >= text.length { break }
                remaining = NSRange(location: next, length: text.length - next)
            }
            return matches
        }
        // Une tâche détachée ne reçoit pas automatiquement l'annulation
        // de son appelant : la transmettre au balayage en cours.
        return await withTaskCancellationHandler {
            let result = await worker.value
            return Task.isCancelled ? [] : result
        } onCancel: {
            worker.cancel()
        }
    }
}
