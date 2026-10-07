import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor CleanupProbe {
    var requests: [URLRequest] = []
    var sawCancellation = false
    func send(_ request: URLRequest) {
        sawCancellation = sawCancellation || Task.isCancelled
        requests.append(request)
    }
    func check(count: Int) {
        precondition(requests.count == count)
        precondition(!sawCancellation, "Cleanup inherited cancelled upload")
        for request in requests {
            precondition(request.httpMethod == "DELETE")
            precondition(request.url?.absoluteString == "https://example.invalid/staging/original-session")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer origin-test-credential")
            precondition(request.timeoutInterval == 15)
        }
    }
}

@main struct UploadSessionCleanupChecks {
    static func main() async {
        let origin = UploadCredential(bearer: "origin-test-credential", fingerprint: "origin")
        precondition(!String(describing: origin).contains("origin-test-credential"))
        precondition(!String(reflecting: origin).contains("origin-test-credential"))
        let url = URL(string: "https://example.invalid/staging/original-session")!
        let probe = CleanupProbe()
        let job = Task {
            // Let cancellation arrive while the original upload is suspended.
            try? await Task.sleep(for: .seconds(30))
            precondition(Task.isCancelled)
            var cleanup = UploadSessionCleanup(url: url, credential: origin)
            await cleanup.cancel { await probe.send($0) }
            await cleanup.cancel { await probe.send($0) }
        }
        job.cancel()
        await job.value
        await probe.check(count: 1)

        var confirmed = UploadSessionCleanup(url: url, credential: origin)
        confirmed.confirmed()
        await confirmed.cancel { await probe.send($0) }
        await probe.check(count: 1)

        var failed = UploadSessionCleanup(url: url, credential: origin)
        await failed.cancel { _ in throw URLError(.notConnectedToInternet) }
        // Best-effort failure neither escapes nor retries under another identity.
        await failed.cancel { await probe.send($0) }
        await probe.check(count: 1)
        print("Upload session cleanup checks passed")
    }
}
