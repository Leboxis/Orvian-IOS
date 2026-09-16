// The CI harness injects the unchanged production scheduling, cancellation
// and publication methods into an ordinary MainActor state holder.
extension TextFileViewer {
    static func checkLifecycle() async {
        let view = TextFileViewer()
        view.isSearching = true
        view.draft = "alpha beta alpha"
        view.searchQuery = "alpha"
        view.scheduleSearchUpdate()
        let beforeErase = view.searchTask!
        view.searchQuery = ""
        view.scheduleSearchUpdate()
        await beforeErase.value
        precondition(view.searchRanges.isEmpty && view.currentSearchIndex == nil,
                     "Erasing the query must invalidate the scheduled result")

        view.searchQuery = "alpha"
        view.scheduleSearchUpdate()
        let beforeClose = view.searchTask!
        view.isSearching = false
        view.scheduleSearchUpdate()
        await beforeClose.value
        precondition(view.searchRanges.isEmpty, "Closing search must keep highlights cleared")

        view.isSearching = true
        view.scheduleSearchUpdate()
        let obsolete = view.searchTask!
        view.searchQuery = "beta"
        view.scheduleSearchUpdate()
        let latest = view.searchTask!
        await obsolete.value
        await latest.value
        precondition(view.searchRanges == [NSRange(location: 6, length: 4)],
                     "Only the latest query may publish")

        view.searchQuery = "alpha"
        view.scheduleSearchUpdate()
        let oldDocument = view.searchTask!
        view.draft = "alpha"
        view.scheduleSearchUpdate()
        await oldDocument.value
        await view.searchTask?.value
        precondition(view.searchRanges == [NSRange(location: 0, length: 5)])

        view.draft = "alpha alpha"
        view.scheduleSearchUpdate()
        await view.searchTask?.value
        view.currentSearchIndex = 1
        view.scheduleSearchUpdate()
        await view.searchTask?.value
        precondition(view.currentSearchIndex == 1, "An unchanged match count preserves selection")

        view.searchQuery = "missing"
        view.scheduleSearchUpdate()
        let beforeDisappear = view.searchTask!
        view.cancelSearch()
        await beforeDisappear.value
        precondition(view.searchRanges.count == 2, "Disappearance must prevent late publication")
    }
}

@main
struct TextSearchLifecycleChecks {
    static func main() async {
        await TextFileViewer.checkLifecycle()
        print("Text search erase, close, replacement, document change and disappearance checks passed")
    }
}
