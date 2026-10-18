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
        print("Details cache, concurrent loading, obsolete responses, account isolation and partial errors checks passed")
    }
}
