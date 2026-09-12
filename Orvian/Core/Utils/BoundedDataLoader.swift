import Foundation

/// Reçoit les documents par blocs sur une file de fond, avec un plafond
/// appliqué même si le serveur ne fournit pas Content-Length.
enum BoundedDataLoader {
    static func load(from url: URL, maximumBytes: Int,
                     configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        let delegate = Delegate(maximumBytes: maximumBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.completion.install(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let completion = TransferCompletion<Data>()
        let maximumBytes: Int
        var data = Data()
        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                completion.finish(.failure(LoadError.invalidResponse))
                completionHandler(.cancel)
                return
            }
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                completion.finish(.failure(LoadError.tooLarge(maximumBytes)))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard chunk.count <= maximumBytes - data.count else {
                completion.finish(.failure(LoadError.tooLarge(maximumBytes)))
                dataTask.cancel()
                return
            }
            data.append(chunk)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { completion.finish(.failure(error)) }
            else { completion.finish(.success(data)) }
        }
    }

    enum LoadError: LocalizedError {
        case invalidResponse, tooLarge(Int)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Le serveur n’a pas pu fournir ce document."
            case let .tooLarge(limit): return "Ce document dépasse la limite de \(limit / 1_024 / 1_024) Mio."
            }
        }
    }
}
