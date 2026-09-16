import Foundation

@main
struct TextSearchChecks {
    static func main() async {
        let document = "😀 Café cafe CAFÉ"
        let ranges = await TextSearch.ranges(query: "cafe", in: document)
        precondition(ranges == [NSRange(location: 3, length: 4),
                                NSRange(location: 8, length: 4),
                                NSRange(location: 13, length: 4)],
                     "Highlights must use UTF-16 offsets, ignoring case and accents")
        let empty = await TextSearch.ranges(query: "", in: document)
        precondition(empty.isEmpty)
        let limited = await TextSearch.ranges(query: "e", in: String(repeating: "e", count: 5_000))
        precondition(limited.count == 2_000)

        // Keep the MainActor occupied until the task is cancelled, so it is
        // guaranteed to enter search already cancelled rather than racing it.
        await checkCancelledSearch()
        print("Text search Unicode, empty query, match limit and cancellation checks passed")
    }

    @MainActor
    static func checkCancelledSearch() async {
        let task = Task { @MainActor in
            await TextSearch.ranges(query: "e", in: String(repeating: "e", count: 5_000))
        }
        task.cancel()
        let ranges = await task.value
        precondition(ranges.isEmpty, "A cancelled search must not return highlights")
    }
}
