import Foundation

/// Décodage borné hors de l'acteur réseau et du thread d'interface.
enum ResponseDecoder {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.orvian.response-decoding"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        try Task.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do { continuation.resume(returning: try JSONDecoder().decode(type, from: data)) }
                catch { continuation.resume(throwing: APIError.decoding(error, raw: Data(data.prefix(16_384)))) }
            }
        }
        try Task.checkCancellation()
        return result
    }
}
