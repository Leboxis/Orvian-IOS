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
        print("Transfer and bounded document checks passed")
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
