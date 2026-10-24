import AVFoundation
import Testing
@testable import Orvian

struct VideoCompatibilityTests {
    @Test(arguments: [AVError.Code.fileFormatNotRecognized, .decoderNotFound])
    func unsupportedMediaEnablesFallback(_ code: AVError.Code) {
        let error = NSError(domain: AVFoundationErrorDomain, code: code.rawValue)
        #expect(VideoPlaybackCompatibility.requiresVLC(for: error))
    }

    @Test(arguments: [AVError.Code.unknown, .decodeFailed, .mediaServicesWereReset, .contentIsNotAuthorized])
    func ambiguousFailuresKeepNativeRecovery(_ code: AVError.Code) {
        let error = NSError(domain: AVFoundationErrorDomain, code: code.rawValue)
        #expect(!VideoPlaybackCompatibility.requiresVLC(for: error))
    }

    @Test
    func networkAndHTTPFailuresOverrideFormatErrors() {
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let wrapped = NSError(domain: AVFoundationErrorDomain,
                              code: AVError.Code.fileFormatNotRecognized.rawValue,
                              userInfo: [NSUnderlyingErrorKey: network])
        #expect(!VideoPlaybackCompatibility.requiresVLC(for: wrapped))
        let unsupported = NSError(domain: AVFoundationErrorDomain,
                                  code: AVError.Code.decoderNotFound.rawValue)
        #expect(!VideoPlaybackCompatibility.requiresVLC(for: unsupported, httpStatusCodes: [403]))
    }
}
