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
        try await checkPipeline(root: root)
        checkParallelProgress()
        print("Upload chunk content, hash, EOF, read failure and cancellation checks passed")
    }

    private static func checkParallelProgress() {
        let progress = UploadChunkProgress(totalSize: 100)
        precondition(progress.update(number: 4, size: 4, fraction: 1) == 0.04,
                     "A short last segment must count its actual bytes")
        precondition(progress.update(number: 1, size: 32, fraction: 0.5) == 0.2)
        precondition(progress.update(number: 1, size: 32, fraction: 0) == 0.2,
                     "Retrying a segment must not double-count or regress progress")
        _ = progress.update(number: 1, size: 32, fraction: 1)
        _ = progress.update(number: 3, size: 32, fraction: 1)
        precondition(progress.update(number: 2, size: 32, fraction: 1) == 1)
    }

    private static func checkPipeline(root: URL) async throws {
        let baseline = try chunkFiles()
        let source = root.appendingPathComponent("parallel-source")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let output = try FileHandle(forWritingTo: source)
        // Fichier creux : quatre segments entiers et un dernier de 17 octets.
        try output.truncate(atOffset: UInt64(4 * 32 * 1_024 * 1_024 + 17))
        try output.close()
        let gate = ChunkTransferGate()
        let reader = try UploadChunkReader(url: source)
        let task = Task {
            try await UploadChunkPipeline.send(reader: reader, totalChunks: 5) { number, payload in
                await gate.transfer(number: number, payload: payload)
            }
            await gate.didFinish()
        }
        while await gate.sizes.count < 4 { await Task.yield() }
        let initial = await gate.sizes
        precondition(initial.count == 4 && initial.values.allSatisfy { $0 == 32 * 1_024 * 1_024 })
        let initialFiles = try chunkFiles().subtracting(baseline)
        precondition(initialFiles.count == 4, "Only four temporary segments may exist at once")
        await gate.release(2)
        while await gate.sizes.count < 5 { await Task.yield() }
        let sizes = await gate.sizes
        precondition(sizes[5] == 17, "Refill must preserve numbering and the short last segment")
        for number in [3, 4, 5] { await gate.release(number) }
        while await gate.completed < 4 { await Task.yield() }
        let premature = await gate.finished
        precondition(!premature, "Push must wait for the first segment too")
        await gate.release(1)
        try await task.value
        let maximum = await gate.maximum
        precondition(maximum == 4, "Transfers must overlap, with a ceiling of four")
        let afterSuccess = try chunkFiles()
        precondition(afterSuccess == baseline, "Success must remove every temporary segment")

        // A child failure must cancel the other transfers and join them before
        // session cleanup. Repeat with explicit parent cancellation.
        for shouldFail in [true, false] {
            let barrier = ChunkStartBarrier()
            let reader = try UploadChunkReader(url: source)
            let failed = Task {
                try await UploadChunkPipeline.send(reader: reader, totalChunks: 4) { number, _ in
                    await barrier.arrive()
                    if shouldFail && number == 2 { throw CocoaError(.fileReadUnknown) }
                    try await Task.sleep(for: .seconds(30))
                }
            }
            while await barrier.count < 4 { await Task.yield() }
            if !shouldFail { failed.cancel() }
            do {
                try await failed.value
                preconditionFailure("Failed/cancelled segments must prevent push")
            } catch {
                if !shouldFail { precondition(error is CancellationError) }
            }
            let afterFailure = try chunkFiles()
            precondition(afterFailure == baseline, "Failure/cancellation must clean every segment")
        }
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

private actor ChunkTransferGate {
    var sizes: [Int: Int] = [:]
    var maximum = 0
    var completed = 0
    var finished = false
    private var active = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func transfer(number: Int, payload: ChunkPayload) async {
        sizes[number] = payload.size
        active += 1
        maximum = max(maximum, active)
        await withCheckedContinuation { waiters[number] = $0 }
        active -= 1
        completed += 1
    }
    func release(_ number: Int) { waiters.removeValue(forKey: number)?.resume() }
    func didFinish() { finished = true }
}

private actor ChunkStartBarrier {
    var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        count += 1
        if count == 4 {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

// Same-file access to the real reader's handle keeps fault injection confined
// to the test executable; no test-only API is added to the app.
extension UploadChunkReader {
    fileprivate func closeInputForCheck() throws {
        try handle.close()
    }
}
