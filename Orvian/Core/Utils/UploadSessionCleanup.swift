import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Credentials live only for this upload, never in defaults or a retry queue.
/// Keep the bearer private and redact descriptions to prevent accidental logging.
struct UploadCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let bearer: String
    let fingerprint: String

    init(bearer: String, fingerprint: String) {
        self.bearer = bearer
        self.fingerprint = fingerprint
    }

    var description: String { "UploadCredential(redacted)" }
    var debugDescription: String { description }

    func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    }
}

/// Only cancels a staging session, never a confirmed file. The caller owns this
/// value on its serial upload flow, and records confirmation before checking
/// cancellation or running any follow-up work.
struct UploadSessionCleanup: Sendable {
    private var request: URLRequest?
    typealias Transport = @Sendable (URLRequest) async throws -> Void

    init(url: URL, credential: UploadCredential) {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        credential.authorize(&request)
        self.request = request
    }

    mutating func confirmed() {
        request = nil
    }

    /// Detached from the cancelled upload, with no lookup of the current account.
    /// Await completion so cleanup is not merely scheduled and forgotten.
    mutating func cancel(transport: @escaping Transport = Self.transmit) async {
        guard let request else { return }
        self.request = nil
        await Task.detached(priority: .utility) {
            try? await transport(request)
        }.value
    }

    private static func transmit(_ request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        // Best effort: a revoked origin token may yield 401. Do not publish an
        // unauthorized notification, retry with a new account, or log the URL.
        _ = try await session.data(for: request)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
