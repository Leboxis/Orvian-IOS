import Foundation

@main struct GridLoadChecks {
    @MainActor static func main() async {
        let vm = FileGridViewModel()
        let loading = Task { await vm.reload() }
        while vm.items.isEmpty || CountServer.shared.pending.isEmpty { await Task.yield() }
        precondition(!vm.isInitialLoading && !vm.isReloading,
                     "The page must display while the count is still pending")
        precondition(vm.totalItemCount == nil)
        CountServer.shared.finish(20)
        await loading.value
        precondition(vm.totalItemCount == 20 && vm.storedCounts.last == 20)

        let interrupted = Task { await vm.reload() }
        while CountServer.shared.pending.isEmpty { await Task.yield() }
        TokenStore.value = "account-b"
        CountServer.shared.finish(99)
        await interrupted.value
        precondition(vm.totalItemCount == 20, "An old session's count must not be published")

        let next = FileGridViewModel()
        let oldCount = Task { await next.reload() }
        while next.items.isEmpty || CountServer.shared.pending.isEmpty { await Task.yield() }
        await next.reload(refreshCount: false)
        CountServer.shared.finish(100)
        await oldCount.value
        precondition(next.totalItemCount == nil, "An old generation must not replace the new count")

        let mutated = FileGridViewModel()
        let duringMutation = Task { await mutated.reload() }
        while mutated.items.isEmpty || CountServer.shared.pending.isEmpty { await Task.yield() }
        mutated.items = []
        CountServer.shared.finish(40)
        await duringMutation.value
        precondition(mutated.totalItemCount == nil,
                     "A count predating a local mutation must not overwrite its result")
        print("Page-before-count, count persistence and obsolete response checks passed")
    }
}
