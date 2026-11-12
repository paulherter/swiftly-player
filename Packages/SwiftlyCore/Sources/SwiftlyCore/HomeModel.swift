import Observation

/// The `@MainActor @Observable` adapter of `HomeVm` (ARCHITECTURE.md D3, contract item 3).
/// A loop over `changed(seen:)` re-reads only the parts that changed, so SwiftUI invalidates
/// only what changed. Views read `status` and `rails` and call the intent helpers; they hold no
/// logic and no text of their own (titles, subtitles and progress come ready from the core).
///
/// Run `observe()` from a `.task` on the view. Cancelling it (the view going away) drops the
/// Rust future; the load itself belongs to the core and goes on.
@MainActor
@Observable
public final class HomeModel {
    /// Where the page stands: loading, ready, offline, signed out.
    public private(set) var status: StatusPart
    /// The rails, with ids of all titles and tile data of the window.
    public private(set) var rails: RailsPart

    @ObservationIgnored private let vm: HomeVm
    @ObservationIgnored private var seen: UInt64

    /// Wraps a view model; the parts are read once so the first frame has data.
    public init(vm: HomeVm) {
        self.vm = vm
        // The version first: a change between the two reads is then seen by the first `changed`.
        self.seen = vm.version()
        self.status = vm.status()
        self.rails = vm.rails()
    }

    /// Where the load stands now, with the reason of a failure (read on demand, not observed: read it when `status` changed).
    public var loadState: LoadState { vm.load().load }

    /// The details of many titles with one request (the TV header's marks); a title the server does not answer for is missing.
    public func tileDetails(ids: [String]) async -> [TileDetails] { (try? await vm.tileDetailsMany(ids: ids)) ?? [] }

    /// The chosen libraries and collections as rows (`startBibliotheken`); call before `load`.
    public func setStartLibraries(_ choice: [HomeLibraryChoice]) { vm.setStartLibraries(choice: choice) }

    /// The stored combined row order (`startReihenfolge`); the rails part updates at once.
    public func setRowOrder(_ order: [String]) { vm.setRowOrder(order: order) }

    /// First appearance or pull to refresh: stored preview, then the server.
    public func load() { vm.send(intent: .load) }

    /// Back in the foreground: reloads only when the rows are 30 s old or older.
    public func refresh() { vm.send(intent: .refresh) }

    /// Another account (or `nil`: signed out). The page is empty at once.
    public func switchAccount(_ account: AccountRef?) { vm.send(intent: .accountSwitched(account: account)) }

    /// A rail scrolled into view: the core prepares tile data for all of it.
    public func railVisible(_ id: String) { vm.send(intent: .visible(rail: id)) }

    /// Tile data beyond the window of a rail.
    public func tiles(rail id: String, from start: Int, count: Int) -> [Tile] {
        vm.tiles(rail: id, start: UInt32(clamping: start), count: UInt32(clamping: count))
    }

    /// The wide picture of a title on the page, for a head that follows the focus (Apple TV): the core's
    /// landscape chain at `width`, else the page-head chain. `nil` when the server has none.
    public func heroImage(of id: String, width: Int) -> ImageRef? {
        vm.heroImage(id: id, width: UInt32(clamping: width))
    }

    /// Starts a load (it always runs) and returns when the page has settled: ready, offline or
    /// signed out. `onChange` is called after every re-read, so a host can show the stored preview
    /// before the server answers. Cancelling the calling Task returns early; the load goes on.
    /// Independent of `observe()`, which may run beside it.
    public func loadSettled(onChange: @MainActor () -> Void = {}) async {
        let railsBit = partRails()
        let statusBit = partStatus()
        var seen = vm.version()
        vm.send(intent: .load)
        let deadline = ContinuousClock.now + .seconds(90)
        while !Task.isCancelled {
            // A run starts inside `send`, so the status already says "loading" or "refreshing".
            let current = vm.status()
            let settled =
                switch current.status {
                case .ready: !current.refreshing
                case .offline, .signedOut: true
                case .loading: false
                }
            if settled || ContinuousClock.now > deadline {
                rails = vm.rails()
                status = current
                onChange()
                return
            }
            do {
                let change = try await vm.changed(seen: seen)
                seen = change.version
                if change.parts & railsBit != 0 { rails = vm.rails() }
                if change.parts & statusBit != 0 { status = vm.status() }
                onChange()
            } catch {
                return  // cancelled
            }
        }
    }

    /// Returns when the calling Task is cancelled (or the view model is gone).
    public func observe() async {
        let railsBit = partRails()
        let statusBit = partStatus()
        while !Task.isCancelled {
            do {
                let change = try await vm.changed(seen: seen)
                seen = change.version
                if change.parts & railsBit != 0 { rails = vm.rails() }
                if change.parts & statusBit != 0 { status = vm.status() }
            } catch {
                return  // cancelled
            }
        }
    }
}
