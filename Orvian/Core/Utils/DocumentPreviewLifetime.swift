import Foundation
import Observation

/// Shared by the screen, QuickLook controller and preview item. The file stays
/// alive until the last consumer (including a presented share sheet) releases it.
final class DocumentPreviewCopy {
    let url: URL

    init(url: URL) { self.url = url }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@MainActor @Observable
final class DocumentPreviewLifetime {
    private(set) var copy: DocumentPreviewCopy?
    private(set) var errorMessage: String?
    private var generation = 0

    func load(_ operation: () async throws -> DocumentPreviewCopy) async {
        // Returning from a QuickLook presentation must not download a second copy.
        guard copy == nil else { return }
        generation &+= 1
        let request = generation
        errorMessage = nil
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            guard generation == request else { return }
            copy = result
        } catch {
            guard generation == request, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelLoading() {
        generation &+= 1
    }
}
