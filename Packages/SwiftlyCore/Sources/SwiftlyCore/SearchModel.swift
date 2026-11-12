import Observation

/// The `@MainActor @Observable` adapter of `SearchVm`. The debounce (0.3 s) and the "latest query
/// wins" rule belong to the core; the view only forwards what is typed.
@MainActor
@Observable
public final class SearchModel {
    /// The result groups (movies, series) for the current query.
    public private(set) var results: SearchResultsPart
    /// Idle, searching, done, empty, offline, signed out.
    public private(set) var status: SearchStatusPart
    /// Recent terms of the account, newest first.
    public private(set) var recents: [String]

    @ObservationIgnored private let vm: SearchVm
    @ObservationIgnored private let seen: UInt64

    public init(vm: SearchVm) {
        self.vm = vm
        self.seen = vm.version()
        self.results = vm.results()
        self.status = vm.status()
        self.recents = vm.recents()
    }

    /// Where the load stands now, with the reason of a failure (read on demand, not observed: read it when `status` changed).
    public var loadState: LoadState { vm.load().load }

    /// The text field changed.
    public func query(_ text: String) { vm.send(intent: .query(text: text)) }
    /// A recent term was tapped.
    public func pick(_ term: String) { vm.send(intent: .pick(term: term)) }
    /// A result was opened: remember the term.
    public func remember() { vm.send(intent: .remember) }
    public func clearRecents() { vm.send(intent: .clearRecents) }
    public func switchAccount(_ account: AccountRef?) { vm.send(intent: .accountSwitched(account: account)) }

    /// Returns when the calling Task is cancelled.
    public func observe() async {
        let resultsBit = partResults()
        let recentsBit = partRecents()
        let vm = vm
        await observeChanges(from: seen, changed: { try await vm.changed(seen: $0) }) { change in
            if change.parts & resultsBit != 0 { results = vm.results() }
            if change.parts & recentsBit != 0 { recents = vm.recents() }
            status = vm.status()
        }
    }

    /// Types the text and returns when the search has an answer for exactly this text (done, empty,
    /// offline or signed out); `nil` when the calling Task was cancelled first. The core debounces.
    public func search(_ text: String) async -> SearchStatus? {
        vm.send(intent: .query(text: text))
        var seen = vm.version()
        let deadline = ContinuousClock.now + .seconds(60)
        while !Task.isCancelled {
            let current = vm.status()
            if current.status != .searching || ContinuousClock.now > deadline {
                results = vm.results()
                status = current
                return current.status
            }
            do {
                seen = try await vm.changed(seen: seen).version
            } catch {
                return nil
            }
        }
        return nil
    }
}
