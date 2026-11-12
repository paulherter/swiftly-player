import Observation

/// The `@MainActor @Observable` adapter of `LibraryVm` (grid of a library, collection or genre).
/// Same contract as `HomeModel`: run `observe()` from a `.task`; the views read `grid` and
/// `status` and send intents, they hold no logic and no text.
@MainActor
@Observable
public final class LibraryModel {
    /// The tiles shown and the total count.
    public private(set) var grid: GridPart
    /// State, sort, filter, paging flags, the reason a watched/watchlist change failed.
    public private(set) var status: LibraryStatusPart

    @ObservationIgnored private let vm: LibraryVm
    @ObservationIgnored private let seen: UInt64

    public init(vm: LibraryVm) {
        self.vm = vm
        self.seen = vm.version()
        self.grid = vm.grid()
        self.status = vm.status()
    }

    /// Where the load stands now, with the reason of a failure (read on demand, not observed: read it when `status` changed).
    public var loadState: LoadState { vm.load().load }

    /// First appearance or pull to refresh.
    public func load() { vm.send(intent: .load) }
    public func setSorting(_ sorting: Sorting) { vm.send(intent: .setSorting(sorting: sorting)) }
    public func setFilter(_ filter: LibraryFilter) { vm.send(intent: .setFilter(filter: filter)) }
    /// The next page now; also the retry after a failure.
    public func loadMore() { vm.send(intent: .loadMore) }
    /// A tile came into view (`columns` tiles per row).
    public func tileVisible(_ id: String, columns: Int) {
        vm.send(intent: .visible(id: id, columns: UInt32(clamping: columns)))
    }
    public func setWatched(_ id: String, _ on: Bool) { vm.send(intent: .setWatched(id: id, on: on)) }
    public func setWatchlist(_ id: String, _ on: Bool) { vm.send(intent: .setWatchlist(id: id, on: on)) }
    public func switchAccount(_ account: AccountRef?) { vm.send(intent: .accountSwitched(account: account)) }

    /// Returns when the calling Task is cancelled.
    public func observe() async {
        let gridBit = partGrid()
        let vm = vm
        await observeChanges(from: seen, changed: { try await vm.changed(seen: $0) }) { change in
            // The status has no bit of its own: it moves with every change.
            if change.parts & gridBit != 0 { grid = vm.grid() }
            status = vm.status()
        }
    }

    /// Sends the sort order and filter (a load starts when either differs, else a plain load) and
    /// returns when the grid has settled: ready, empty, offline or signed out. Cancelling the calling
    /// Task returns early; the load goes on. Independent of `observe()`.
    public func loadSettled(sorting: Sorting, filter: LibraryFilter) async {
        let current = vm.status()
        if current.sorting != sorting || current.filter != filter {
            if current.sorting != sorting { vm.send(intent: .setSorting(sorting: sorting)) }
            if current.filter != filter { vm.send(intent: .setFilter(filter: filter)) }
        } else {
            vm.send(intent: .load)
        }
        await settle()
    }

    /// Fetches the whole list of the order on screen once (so the strip covers every title) and gives the
    /// letter strip. A failed fetch leaves the strip on the loaded titles.
    public func alphabetSettled() async -> AlphabetPart {
        try? await vm.loadAlphabet()
        return vm.alphabet()
    }

    /// The strip key of a loaded title, against the strip last handed out.
    public func keyOf(_ id: String) -> String? { vm.keyOf(id: id) }

    /// The id of the first loaded title under `key`; `nil` when it is not loaded yet.
    public func jumpTargetID(_ key: String) -> String? {
        guard let index = vm.jumpTarget(key: key) else { return nil }
        let tiles = vm.grid().tiles
        return Int(index) < tiles.count ? tiles[Int(index)].id : nil
    }

    /// Asks for the next page and returns when it has arrived (or failed).
    public func loadMoreSettled() async {
        vm.send(intent: .loadMore)
        await settle()
    }

    private func settle() async {
        var seen = vm.version()
        let deadline = ContinuousClock.now + .seconds(90)
        while !Task.isCancelled {
            let current = vm.status()
            // `refreshing` covers the quiet refresh: titles are shown, so the status stays `.ready`,
            // but the page of the new order or filter is still on its way.
            if current.status != .loading && !current.refreshing && !current.loadingMore
                || ContinuousClock.now > deadline
            {
                grid = vm.grid()
                status = current
                return
            }
            do {
                seen = try await vm.changed(seen: seen).version
            } catch {
                return  // cancelled
            }
        }
    }
}
