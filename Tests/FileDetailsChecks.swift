import Foundation

@main struct FileDetailsChecks {
    @MainActor static func main() async {
        let model = FileDetailsViewModel()
        let server = DetailsServer.shared
        let known = DriveFile(id: 1, path: "/known", categories: [FileCategory(categoryId: 1)])
        await model.load(file: known, driveId: 42, isTrashed: false)
        precondition(server.pending.isEmpty && model.categories.map(\.id) == [1])
        let first = Task { await model.load(file: DriveFile(id: 2), driveId: 42, isTrashed: false) }
        while server.pending.count < 1 { await Task.yield() }
        let latest = Task { await model.load(file: DriveFile(id: 3), driveId: 42, isTrashed: false) }
        while server.pending.count < 2 { await Task.yield() }
        server.finish(1, file: DriveFile(id: 3, path: "/new", categories: []))
        await latest.value
        server.finish(0, file: DriveFile(id: 2, path: "/old", categories: [FileCategory(categoryId: 1)]))
        await first.value
        precondition(model.file?.id == 3 && model.categories.isEmpty, "An obsolete file must not replace the current inspector")
        let changingAccount = Task { await model.load(file: DriveFile(id: 4), driveId: 42, isTrashed: false) }
        while server.pending.count < 3 { await Task.yield() }
        TokenStore.value = "b"
        server.finish(2, file: DriveFile(id: 4, path: "/private", categories: [FileCategory(categoryId: 1)]))
        await changingAccount.value
        precondition(model.file?.path == nil && model.categories.isEmpty)
        let failing = Task { await model.load(file: DriveFile(id: 5), driveId: 42, isTrashed: false) }
        while server.pending.count < 4 { await Task.yield() }
        server.fail(3)
        await failing.value
        precondition(model.file?.name == "Known name" && model.infoError != nil && model.tagsError != nil)
        let partial = Task { await model.load(file: DriveFile(id: 7, categories: [FileCategory(categoryId: 1)]), driveId: 42, isTrashed: false) }
        while server.pending.count < 5 { await Task.yield() }
        precondition(model.categories.map(\.id) == [1], "Known tags must display before the file-info request finishes")
        server.fail(4)
        await partial.value
        precondition(model.infoError != nil && model.tagsError == nil && model.categories.map(\.id) == [1])
        await model.load(file: DriveFile(id: 8, path: "/unknown-tag", categories: [FileCategory(categoryId: 99)]), driveId: 42, isTrashed: false)
        precondition(model.tagsError != nil, "Unresolvable membership must not be announced as no tags")
        await model.load(file: DriveFile(id: 6), driveId: 42, isTrashed: true)
        precondition(server.pending.count == 5 && !model.isLoading)

        let library = CategoryLibrary.shared
        library.loaded = false
        let parallel = Task {
            await model.load(file: DriveFile(id: 9, categories: [FileCategory(categoryId: 1)]), driveId: 42, isTrashed: false)
        }
        // Both requests must start before either is allowed to complete.
        while server.pending.count < 6 || library.pending == nil { await Task.yield() }
        library.finish()
        while model.categories.isEmpty { await Task.yield() }
        precondition(model.isLoading && model.file?.path == nil,
                     "Tags must display while the path request is still suspended")
        server.finish(5, file: DriveFile(id: 9, path: "/parallel", categories: [FileCategory(categoryId: 1)]))
        await parallel.value

        library.loaded = false
        let slowTags = Task { await model.load(file: DriveFile(id: 10), driveId: 42, isTrashed: false) }
        while server.pending.count < 7 || library.pending == nil { await Task.yield() }
        server.finish(6, file: DriveFile(id: 10, path: "/ready", categories: []))
        while model.file?.path == nil { await Task.yield() }
        precondition(model.isLoading && library.pending != nil,
                     "File facts must display while the tag library is still suspended")
        library.finish()
        await slowTags.value
        precondition(!model.isLoading && model.infoError == nil && model.tagsError == nil)
        let preparedFile = DriveFile(id: 11, categories: [])
        let preparing = Task { await model.loadIfNeeded(file: preparedFile, driveId: 42, isTrashed: false) }
        while server.pending.count < 8 { await Task.yield() }
        precondition(model.isLoading && !model.isLoadingTags, "Known empty tags must not wait for a missing path")
        await model.loadIfNeeded(file: preparedFile, driveId: 42, isTrashed: false)
        precondition(server.pending.count == 8, "Opening the inspector must reuse the menu's in-flight request")
        server.finish(7, file: DriveFile(id: 11, path: "/prepared", categories: []))
        await preparing.value
        await model.loadIfNeeded(file: preparedFile, driveId: 42, isTrashed: false)
        precondition(server.pending.count == 8, "Reopening recent details must not repeat the GET")
        TokenStore.value = "new-account"
        let newAccount = Task { await model.loadIfNeeded(file: preparedFile, driveId: 42, isTrashed: false) }
        while server.pending.count < 9 { await Task.yield() }
        server.finish(8, file: DriveFile(id: 11, path: "/new-account", categories: []))
        await newAccount.value
        precondition(model.file?.path == "/new-account", "Prepared details must remain scoped to the account")
        let sizes = FolderSizeServer.shared
        let folder = DriveFile(id: 20, path: "/folder", categories: [], size: 0, isDirectory: true)
        let folderLoad = Task { await model.loadIfNeeded(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 1 { await Task.yield() }
        precondition(model.folderSize == nil && model.isLoadingFolderSize,
                     "A listing size of zero is not an empty folder")
        precondition(server.pending.count == 9, "Known path/tags must not prevent the independent size GET")
        sizes.finish(0, size: 5_000_000_000)
        await folderLoad.value
        precondition(model.folderSize == 5_000_000_000 && model.folderSizeError == nil && !model.isLoadingFolderSize)
        await model.loadIfNeeded(file: folder, driveId: 42, isTrashed: false)
        precondition(sizes.pending.count == 1, "Reopening recent details must reuse the verified total")

        let emptyLoad = Task { await model.load(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 2 { await Task.yield() }
        sizes.finish(1, size: 0)
        await emptyLoad.value
        precondition(model.folderSize == 0, "Only the dedicated API can confirm zero bytes")

        let sizeFailure = Task { await model.load(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 3 { await Task.yield() }
        sizes.fail(2)
        await sizeFailure.value
        precondition(model.folderSize == nil && model.folderSizeError != nil && model.infoError == nil)
        let retrySize = Task { await model.loadIfNeeded(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 4 { await Task.yield() }
        sizes.finish(3, size: 12)
        await retrySize.value
        precondition(model.folderSize == 12, "An error must not be cached as a successful total")

        let staleSize = Task { await model.load(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 5 { await Task.yield() }
        await model.load(file: known, driveId: 42, isTrashed: false)
        sizes.finish(4, size: 999)
        await staleSize.value
        precondition(model.file?.id == known.id && model.folderSize == nil, "Obsolete totals must not leak to another file")

        let previousCredential = TokenStore.value
        let switchedSize = Task { await model.load(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 6 { await Task.yield() }
        precondition(sizes.credentials.last == TokenStore.value)
        TokenStore.value = "another-account"
        sizes.finish(5, size: 888)
        await switchedSize.value
        precondition(model.folderSize == nil && model.folderSizeError == nil, "A previous account’s total must be ignored")

        TokenStore.value = previousCredential
        let returnedAccount = Task { await model.loadIfNeeded(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 7 { await Task.yield() }
        sizes.finish(6, size: 13)
        await returnedAccount.value
        precondition(model.folderSize == 13, "Discarded account responses must not count as cached success")

        let cancelledSize = Task { await model.load(file: folder, driveId: 42, isTrashed: false) }
        while sizes.pending.count < 8 { await Task.yield() }
        cancelledSize.cancel()
        sizes.finish(7, size: 777)
        await cancelledSize.value
        precondition(model.folderSize == nil && model.folderSizeError == nil && !model.isLoadingFolderSize)
        await model.load(file: folder, driveId: 42, isTrashed: true)
        precondition(sizes.pending.count == 8 && model.folderSize == nil && !model.isLoadingFolderSize,
                     "The live sizes endpoint must not be used for trash")
        print("Details cache, concurrent loading, folder totals, cancellation, account isolation and partial errors checks passed")
    }
}
