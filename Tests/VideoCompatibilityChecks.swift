import Foundation

@main
struct VideoCompatibilityChecks {
    static func main() {
        func av(_ code: Int, _ underlying: NSError? = nil) -> NSError {
            NSError(domain: "AVFoundationErrorDomain", code: code,
                    userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        func check(_ error: Error?, _ expected: Bool, statuses: [Int] = []) {
            precondition(VideoPlaybackCompatibility.requiresVLC(for: error, httpStatusCodes: statuses) == expected)
        }
        check(nil, false)
        check(av(-11828), true)
        check(av(-11833), true)
        check(av(-11800, av(-11833)), true)
        check(av(-11821), false) // Generic decode failure may mean damaged media.
        check(av(-11819), false) // Reset media services, not an unsupported codec.
        check(av(-11835), false)
        check(NSError(domain: "Other", code: -11828), false)
        check(NSError(domain: "Other", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "Unsupported MKV codec"]), false)
        for code in [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
                     NSURLErrorUserAuthenticationRequired, NSURLErrorCancelled,
                     NSURLErrorSecureConnectionFailed] {
            let network = NSError(domain: NSURLErrorDomain, code: code)
            check(network, false)
            check(av(-11828, network), false)
            check(av(-11800, av(-11833, network)), false)
        }
        for status in [401, 403, 404, 429, 500, 503] {
            check(av(-11828), false, statuses: [status])
        }
        check(av(-11828), true, statuses: [200, 206])
        check(av(-11828, av(-11835)), false)
        check(NSError(domain: "AVFoundationErrorDomain", code: -11828,
                      userInfo: ["NSMultipleUnderlyingErrors": [av(-11833),
                          NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)]]), false)
        print("Video compatibility checks passed")
    }
}
