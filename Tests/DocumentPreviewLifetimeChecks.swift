import Foundation

@MainActor
private final class DeferredPreview {
    private var continuation: CheckedContinuation<DocumentPreviewCopy, Error>?
    var isWaiting: Bool { continuation != nil }

    func value() async throws -> DocumentPreviewCopy {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ copy: DocumentPreviewCopy) {
        let waiting = continuation
        continuation = nil
        waiting!.resume(returning: copy)
    }
}

@main
struct DocumentPreviewLifetimeChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentPreviewLifetimeChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeCopy(_ name: String) throws -> DocumentPreviewCopy {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("document.pdf")
            try Data("preview".utf8).write(to: url)
            return DocumentPreviewCopy(url: url)
        }
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        func waitForRequest(_ deferred: DeferredPreview) async {
            for _ in 0..<1_000 {
                if deferred.isWaiting { return }
                await Task.yield()
            }
            preconditionFailure("Preview operation never started")
        }

        var screen: DocumentPreviewLifetime? = DocumentPreviewLifetime()
        await screen!.load { try makeCopy("active") }
        precondition(screen!.copy != nil && exists("active"))
        screen!.cancelLoading()
        var requests = 0
        await screen!.load {
            requests += 1
            return try makeCopy("unexpected-duplicate")
        }
        precondition(requests == 0, "Reappearance redownloaded an active preview")

        // Releasing the SwiftUI host cannot remove a file still owned by
        // QuickLook or by a consumer retaining its preview item for sharing.
        var controller: DocumentPreviewCopy? = screen!.copy
        var shareItem: DocumentPreviewCopy? = controller
        screen = nil
        precondition(exists("active"))
        controller = nil
        precondition(exists("active"))
        precondition(shareItem?.url.lastPathComponent == "document.pdf")
        shareItem = nil
        precondition(!exists("active"), "Successful preview leaked after its final consumer released it")

        // A dismissed request may finish even when the transport ignored cancel.
        let lifetime = DocumentPreviewLifetime()
        let late = DeferredPreview()
        let lateTask = Task { await lifetime.load { try await late.value() } }
        await waitForRequest(late)
        lifetime.cancelLoading()
        await lifetime.load { try makeCopy("replacement") }
        late.finish(try makeCopy("late"))
        await lateTask.value
        precondition(!exists("late"), "Dismissed request retained a late download")
        precondition(lifetime.copy?.url.deletingLastPathComponent().lastPathComponent == "replacement")

        let cancelledLifetime = DocumentPreviewLifetime()
        let cancelled = DeferredPreview()
        let cancelledTask = Task { await cancelledLifetime.load { try await cancelled.value() } }
        await waitForRequest(cancelled)
        cancelledTask.cancel()
        cancelled.finish(try makeCopy("cancelled"))
        await cancelledTask.value
        precondition(cancelledLifetime.copy == nil && cancelledLifetime.errorMessage == nil)
        precondition(!exists("cancelled"), "Cancellation retained a completed copy")

        // Failed requests can retry, and releasing an older presentation cannot
        // delete the independently owned file of a newly opened preview.
        var retryLifetime: DocumentPreviewLifetime? = DocumentPreviewLifetime()
        await retryLifetime!.load { throw NSError(domain: "PreviewTest", code: 1) }
        precondition(retryLifetime!.errorMessage != nil)
        await retryLifetime!.load { try makeCopy("retry") }
        precondition(retryLifetime!.errorMessage == nil && retryLifetime!.copy != nil)
        var oldController: DocumentPreviewCopy? = retryLifetime!.copy
        retryLifetime = nil
        let newLifetime = DocumentPreviewLifetime()
        await newLifetime.load { try makeCopy("new") }
        precondition(exists("retry") && exists("new"))
        precondition(oldController?.url.lastPathComponent == "document.pdf")
        oldController = nil
        precondition(!exists("retry") && exists("new"))

        // Repeated open/close frees each owned directory in the same process.
        for index in 0..<10 {
            var preview: DocumentPreviewLifetime? = DocumentPreviewLifetime()
            let name = "repeat-\(index)"
            await preview!.load { try makeCopy(name) }
            preview = nil
            precondition(!exists(name))
        }
        print("Preview lifetime checks passed: final-release cleanup, sharing, stale/cancelled loads, retries and reappearance")
    }
}
