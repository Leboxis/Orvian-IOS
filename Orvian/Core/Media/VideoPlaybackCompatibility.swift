import Foundation

/// A network/authentication failure must never be mistaken for a codec failure.
enum VideoPlaybackCompatibility {
    static func requiresVLC(for error: Error?, httpStatusCodes: [Int] = []) -> Bool {
        guard let error, !httpStatusCodes.contains(where: { (400...599).contains($0) }) else { return false }
        var pending = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        var hasUnsupportedFormat = false
        while let current = pending.popLast() {
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            // Even an AVFoundation format error can wrap an HTTP/URL failure.
            if current.domain == NSURLErrorDomain { return false }
            if current.domain == "AVFoundationErrorDomain" {
                switch current.code {
                case -11828, -11833: // fileFormatNotRecognized, decoderNotFound
                    hasUnsupportedFormat = true
                case -11835: // contentIsNotAuthorized
                    return false
                default:
                    break
                }
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let underlying = current.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
                pending.append(contentsOf: underlying)
            }
        }
        return hasUnsupportedFormat
    }
}
