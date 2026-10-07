import Foundation

struct FileCategory: Sendable { let categoryId: Int }
struct DriveFile: Sendable {
    let id: Int
    var categories: [FileCategory]? = nil
}
struct Category { let id: Int }
enum TokenStore {
    static var value: String? = "account-a"
    static func credentialFingerprint() -> String? { value }
}

struct TagRequest: Equatable, Sendable {
    let files: [Int]
    let category: Int
    let isAdd: Bool
    let bulk: Bool
}

actor TagServer {
    static let shared = TagServer()
    var calls: [TagRequest] = []
    var failedPairs: Set<String> = []
    var failBulk = false
    var switchAccount = false
    var holdBulk = false
    var waiting: CheckedContinuation<Void, Never>?

    func configure(failBulk: Bool = false, failedPairs: Set<String> = [],
                   switchAccount: Bool = false, holdBulk: Bool = false) {
        calls = []
        self.failBulk = failBulk
        self.failedPairs = failedPairs
        self.switchAccount = switchAccount
        self.holdBulk = holdBulk
    }
    func request(_ call: TagRequest, credential: String?) async throws {
        precondition(credential == "account-a", "All requests retain the captured identity")
        calls.append(call)
        if call.bulk && holdBulk {
            await withCheckedContinuation { waiting = $0 }
        }
        if switchAccount { TokenStore.value = "account-b" }
        if call.bulk && failBulk {
            throw APIError.http(status: 500, code: nil, description: "bulk failure")
        }
        if !call.bulk && failedPairs.contains("\(call.files[0]):\(call.category)") {
            throw APIError.http(status: 403, code: nil, description: "pair failure")
        }
    }
    func release() { waiting?.resume(); waiting = nil }
    func isWaiting() -> Bool { waiting != nil }
}

struct KDriveService {
    func addCategory(driveId: Int, fileIds: [Int], categoryId: Int, credentialFingerprint: String?) async throws {
        try await TagServer.shared.request(TagRequest(files: fileIds, category: categoryId, isAdd: true, bulk: true), credential: credentialFingerprint)
    }
    func removeCategory(driveId: Int, fileIds: [Int], categoryId: Int, credentialFingerprint: String?) async throws {
        try await TagServer.shared.request(TagRequest(files: fileIds, category: categoryId, isAdd: false, bulk: true), credential: credentialFingerprint)
    }
    func addCategory(driveId: Int, fileId: Int, categoryId: Int, credentialFingerprint: String?) async throws {
        try await TagServer.shared.request(TagRequest(files: [fileId], category: categoryId, isAdd: true, bulk: false), credential: credentialFingerprint)
    }
    func removeCategory(driveId: Int, fileId: Int, categoryId: Int, credentialFingerprint: String?) async throws {
        try await TagServer.shared.request(TagRequest(files: [fileId], category: categoryId, isAdd: false, bulk: false), credential: credentialFingerprint)
    }
}

@main struct TagApplyChecks {
    @MainActor static func main() async {
        let server = TagServer.shared
        let empty = [DriveFile(id: 1), DriveFile(id: 2), DriveFile(id: 3)]
        let tagged = empty.map { DriveFile(id: $0.id, categories: [FileCategory(categoryId: 10)]) }

        // Both add and remove: total fallback success suppresses the bulk error.
        for isAdd in [true, false] {
            TokenStore.value = "account-a"
            await server.configure(failBulk: true)
            let sheet = TagSheetHarness(isAdd ? empty : tagged)
            if isAdd { sheet.addIDs = [10] } else { sheet.removeIDs = [10] }
            await sheet.apply()
            precondition(sheet.errorMessage == nil && sheet.dismissed)
            precondition(sheet.deliveries.count == 1 && sheet.deliveries[0].count == 3)
            precondition(sheet.countHaving(10) == (isAdd ? 3 : 0))
            precondition(sheet.addIDs.isEmpty && sheet.removeIDs.isEmpty)
        }

        // Multi-category partial success: retry sends only failed file/tag pairs,
        // including its fallback, and never republishes a prior confirmed pair.
        for isAdd in [true, false] {
            TokenStore.value = "account-a"
            await server.configure(failBulk: true, failedPairs: ["2:10"])
            let files = isAdd ? empty : tagged.map {
                DriveFile(id: $0.id, categories: [FileCategory(categoryId: 10), FileCategory(categoryId: 20)])
            }
            let sheet = TagSheetHarness(files)
            if isAdd { sheet.addIDs = [10, 20] } else { sheet.removeIDs = [10, 20] }
            await sheet.apply()
            precondition(!sheet.dismissed && sheet.errorMessage != nil)
            precondition(sheet.countHaving(10) == (isAdd ? 2 : 1))
            precondition(sheet.countHaving(20) == (isAdd ? 3 : 0))
            precondition((isAdd ? sheet.addIDs : sheet.removeIDs) == [10])
            precondition(sheet.deliveries.flatMap { $0 }.count == 5)
            await server.configure(failBulk: true)
            await sheet.apply()
            let retryCalls = await server.calls
            precondition(retryCalls.count == 2)
            precondition(retryCalls.allSatisfy { $0.files == [2] && $0.category == 10 && $0.isAdd == isAdd })
            precondition(sheet.dismissed && sheet.errorMessage == nil)
            precondition(sheet.deliveries.flatMap { $0 }.count == 6)
        }

        // Correcting a failed addition uses the rebased partial state: remove
        // only the confirmed additions, then the pending selection is settled.
        TokenStore.value = "account-a"
        await server.configure(failBulk: true, failedPairs: ["2:10"])
        let correction = TagSheetHarness(empty)
        correction.addIDs = [10]
        await correction.apply()
        correction.toggle(Category(id: 10))
        precondition(correction.addIDs.isEmpty && correction.removeIDs == [10])
        precondition(correction.errorMessage == nil)
        await server.configure()
        await correction.apply()
        let correctionCalls = await server.calls
        precondition(correctionCalls == [TagRequest(files: [1, 3], category: 10, isAdd: false, bulk: true)])
        precondition(correction.countHaving(10) == 0 && correction.dismissed)

        // Correcting a failed removal can restore only the confirmed removals.
        await server.configure(failBulk: true, failedPairs: ["2:10"])
        let restore = TagSheetHarness(tagged)
        restore.removeIDs = [10]
        await restore.apply()
        restore.toggle(Category(id: 10)) // Cancel the outstanding removal.
        precondition(restore.addIDs.isEmpty && restore.removeIDs.isEmpty)
        precondition(restore.countHaving(10) == 1 && restore.errorMessage == nil)
        restore.toggle(Category(id: 10)) // Complete membership again.
        precondition(restore.addIDs == [10])
        await server.configure()
        await restore.apply()
        let restoreCalls = await server.calls
        precondition(restoreCalls == [TagRequest(files: [1, 3], category: 10, isAdd: true, bulk: true)])
        precondition(restore.countHaving(10) == 3 && restore.dismissed)

        // Remaining intents can also be cancelled without reverting successes.
        await server.configure(failBulk: true, failedPairs: ["2:10"])
        let cancelledSelection = TagSheetHarness(empty)
        cancelledSelection.addIDs = [10]
        await cancelledSelection.apply()
        cancelledSelection.toggle(Category(id: 10))
        cancelledSelection.toggle(Category(id: 10))
        precondition(cancelledSelection.addIDs.isEmpty && cancelledSelection.removeIDs.isEmpty)
        precondition(cancelledSelection.countHaving(10) == 2 && cancelledSelection.errorMessage == nil)

        // Existing memberships are not replayed, even on the first attempt.
        await server.configure()
        let existing = TagSheetHarness([DriveFile(id: 1, categories: [FileCategory(categoryId: 10)]), DriveFile(id: 2)])
        existing.addIDs = [10]
        await existing.apply()
        let existingCalls = await server.calls
        precondition(existingCalls == [TagRequest(files: [2], category: 10, isAdd: true, bulk: true)])

        // Identity changing during bulk prevents fallback, reconciliation and UI delivery.
        for failBulk in [true, false] {
            TokenStore.value = "account-a"
            await server.configure(failBulk: failBulk, switchAccount: true)
            let stale = TagSheetHarness(empty)
            stale.addIDs = [10]
            await stale.apply()
            let staleCalls = await server.calls
            precondition(staleCalls.count == 1)
            precondition(stale.deliveries.isEmpty && stale.confirmedTagOverrides.isEmpty && !stale.dismissed)
        }

        // Cancellation while the network response is suspended also prevents fallback.
        TokenStore.value = "account-a"
        await server.configure(failBulk: true, holdBulk: true)
        let cancelled = TagSheetHarness(empty)
        cancelled.addIDs = [10]
        let task = Task { await cancelled.apply() }
        while !(await server.isWaiting()) { await Task.yield() }
        cancelled.toggle(Category(id: 20))
        await cancelled.apply() // Duplicate confirmation is ignored while busy.
        precondition(cancelled.addIDs == [10], "Selection is locked during an attempt")
        task.cancel()
        await server.release()
        await task.value
        let cancelledCalls = await server.calls
        precondition(cancelledCalls.count == 1 && cancelled.deliveries.isEmpty && !cancelled.dismissed)
        precondition(!cancelled.busy)

        // Callback suspension must not dismiss into a replacement identity.
        TokenStore.value = "account-a"
        await server.configure()
        let callback = TagSheetHarness(empty)
        callback.addIDs = [10]
        callback.changeIdentityOnDone = true
        await callback.apply()
        precondition(callback.deliveries.count == 1 && !callback.dismissed)
        print("Tag fallback, pair-only retries, selection reconciliation and session checks passed")
    }
}
