// Appended to the production UploadChunkReader declaration by the CI script.
@main
struct UploadChunkChecks {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let data = Data(repeating: 0x61, count: (1 << 20) + 17)
        try data.write(to: source)
        let reader = try UploadChunkReader(url: source)
        let first = try await reader.next(maxLength: 1 << 20)!
        let second = try await reader.next(maxLength: 1 << 20)!
        defer {
            try? manager.removeItem(at: first.url)
            try? manager.removeItem(at: second.url)
        }
        let firstData = try Data(contentsOf: first.url)
        precondition(firstData == data.prefix(1 << 20))
        precondition(first.size == 1 << 20 && second.size == 17)
        let expectedHash = SHA256.hash(data: firstData).map { String(format: "%02x", $0) }.joined()
        precondition(first.sha256 == expectedHash)

        let before = try chunkFiles()
        let eof = try await reader.next(maxLength: 1 << 20)
        precondition(eof == nil)
        let afterEOF = try chunkFiles()
        precondition(afterEOF == before, "EOF must not leave an empty chunk")

        // Close a valid input before reading. Opening a directory is not a
        // portable failure fixture: some Foundation versions reject it during
        // initialization, before next() can exercise output cleanup.
        let unreadable = try UploadChunkReader(url: source)
        try await unreadable.closeInputForCheck()
        do {
            _ = try await unreadable.next(maxLength: 1 << 20)
            preconditionFailure("Reading a closed input must fail")
        } catch {}
        let afterFailure = try chunkFiles()
        precondition(afterFailure == before, "A read error must remove its partial output")

        let cancellationReader = try UploadChunkReader(url: source)
        await checkCancellation(reader: cancellationReader)
        let afterCancellation = try chunkFiles()
        precondition(afterCancellation == before, "Cancellation must not leak temporary chunks")
        print("Upload chunk content, hash, EOF, read failure and cancellation checks passed")
    }

    static func chunkFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("orvian-chunk-") })
    }

    @MainActor
    private static func checkCancellation(reader: UploadChunkReader) async {
        let task = Task { @MainActor in try await reader.next(maxLength: 1 << 20) }
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("A cancelled chunk read must throw")
        } catch is CancellationError {} catch { preconditionFailure("Unexpected error: \(error)") }
    }
}

// Same-file access to the real reader's handle keeps fault injection confined
// to the test executable; no test-only API is added to the app.
extension UploadChunkReader {
    fileprivate func closeInputForCheck() throws {
        try handle.close()
    }
}
