import Foundation

@main
struct TransferChecks {
    static func main() async throws {
        let early = TransferCompletion<Int>()
        early.finish(.failure(CancellationError()))
        do {
            _ = try await withCheckedThrowingContinuation { early.install($0) }
            preconditionFailure("An early cancellation must be delivered")
        } catch is CancellationError {} catch { throw error }

        for _ in 0..<250 {
            let completion = TransferCompletion<Int>()
            let result: Int = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async { completion.install(continuation) }
                DispatchQueue.concurrentPerform(iterations: 4) { index in
                    completion.finish(.success(index))
                }
            }
            precondition((0..<4).contains(result))
            precondition(!completion.finish(.success(9)), "Duplicate callbacks must be ignored")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DocumentProtocol.self]
        let exact = try await BoundedDataLoader.load(from: URL(string: "https://test.local/exact")!,
                                                    maximumBytes: 6, configuration: configuration)
        precondition(exact == Data("abcdef".utf8))
        for path in ["chunked-overflow", "announced-overflow", "http-error"] {
            do {
                _ = try await BoundedDataLoader.load(from: URL(string: "https://test.local/\(path)")!,
                                                     maximumBytes: 5, configuration: configuration)
                preconditionFailure("Rejected document was accepted: \(path)")
            } catch is BoundedDataLoader.LoadError {} catch { throw error }
        }
        try checkUploadRetrySources()
        print("Transfer and bounded document checks passed")
    }

    private static func checkUploadRetrySources() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let service = try String(
            contentsOf: repository.appendingPathComponent("Orvian/Core/API/KDriveService+Upload.swift"),
            encoding: .utf8
        )
        let manager = try String(
            contentsOf: repository.appendingPathComponent("Orvian/Core/Upload/UploadManager.swift"),
            encoding: .utf8
        )
        let sheet = try String(
            contentsOf: repository.appendingPathComponent("Orvian/UI/UploadProgressSheet.swift"),
            encoding: .utf8
        )

        precondition(service.contains("directUploadMaximumAttempts = 3"), "Direct retries must stay bounded")
        precondition(service.contains("UploadSafety.mayRetryDirectUpload(error)"))
        precondition(service.contains("throw UploadOutcomeUnknown()"))
        // Une confirmation perdue après création ne doit jamais rejouer un POST.
        let ambiguous: [Error] = [
            APIError.network(URLError(.networkConnectionLost)),
            APIError.network(URLError(.timedOut)),
            APIError.http(status: 408, code: nil, description: nil),
            APIError.http(status: 503, code: nil, description: nil),
            APIError.invalidResponse,
            APIError.decoding(URLError(.cannotDecodeContentData), raw: nil),
        ]
        for error in ambiguous {
            precondition(!UploadSafety.mayRetryDirectUpload(error))
            precondition(UploadSafety.outcomeMayBeUnknown(error))
        }
        let refused = APIError.http(status: 429, code: nil, description: nil)
        precondition(UploadSafety.mayRetryDirectUpload(refused))
        precondition(!UploadSafety.outcomeMayBeUnknown(refused))
        for status in [400, 401, 403, 413] {
            let error = APIError.http(status: status, code: nil, description: nil)
            precondition(!UploadSafety.mayRetryDirectUpload(error))
            precondition(!UploadSafety.outcomeMayBeUnknown(error))
        }
        precondition(!UploadSafety.mayRetryDirectUpload(CancellationError()))
        precondition(manager.contains("if error is UploadOutcomeUnknown"),
                     "An uncertain upload must not offer a manual retry")
        precondition(service.contains("try Task.checkCancellation()") && service.contains("Task.sleep(for:"))
        precondition(service.contains("attemptStarted(attempt)"), "Each attempt must reset progress")

        precondition(manager.contains("retryContexts"), "Failed tasks must retain their retry source")
        precondition(manager.contains("retryContext.source = .payload(payload)"))
        precondition(manager.contains("func retryUpload(taskId: UUID)"))
        precondition(manager.contains("discardRetryContexts(for:"), "Clearing tasks must clean retained files")
        precondition(manager.contains("discardRetryContexts(for: Set(retryContexts.keys))"), "Logout must clean retries")
        precondition(manager.contains("discardRetryContexts(for: discardedTaskIDs)"), "Clear must clean retries")
        precondition(manager.contains("let shouldRemoveTemporaryFile = result != nil"), "Success must clean its temporary file")
        precondition(manager.contains("context.onDone?([uploadedFile])"), "A successful manual retry must keep callbacks")
        precondition(sheet.contains("manager.retryUpload(taskId: task.id)"), "Failed rows need a retry action")
    }
}

private final class DocumentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "http-error" ? 503 : 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: path == "announced-overflow" ? ["Content-Length": "100"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("abc".utf8))
        client?.urlProtocol(self, didLoad: Data("def".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
