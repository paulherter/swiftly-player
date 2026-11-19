import Observation

/// **The server management page** (`ServerAdminVm`) as an observable adapter, the same on every Apple platform.
///
/// The core owns the words, the numbers, the confirm questions and the refresh rhythm; the adapter keeps the last
/// `part` and forwards the intents. `run()` is the page's life: it asks the core to refresh while the page is on screen
/// (`Start`) and to stop when the page goes (`Stop`), so nothing polls the server in the background. Call it from a
/// `.task`: cancelling the task (the page disappearing) ends the loop and sends `Stop`.
@MainActor
@Observable
public final class ServerAdminModel {
    /// What the page draws: loading, ready (with the whole page), failed, not allowed.
    public private(set) var part: ServerAdminPart

    @ObservationIgnored private let vm: ServerAdminVm

    public init(vm: ServerAdminVm) {
        self.vm = vm
        self.part = vm.part()
    }

    /// Forwards a tap; the part is read again right away so the answer (a question, a notice) shows in the same frame.
    public func send(_ intent: ServerAdminIntent) {
        vm.send(intent: intent)
        part = vm.part()
    }

    /// Refresh while this runs. Returns when the calling Task is cancelled.
    public func run() async {
        vm.send(intent: .start)
        part = vm.part()
        let vm = vm
        await observeChanges(from: part.version, changed: { try await vm.changed(seen: $0) }) { _ in
            part = vm.part()
        }
        vm.send(intent: .stop)
    }
}

/// **The log screen** (`ServerLogsVm`): the file list, then one file.
@MainActor
@Observable
public final class ServerLogsModel {
    public private(set) var part: ServerLogsPart

    @ObservationIgnored private let vm: ServerLogsVm

    public init(vm: ServerLogsVm) {
        self.vm = vm
        self.part = vm.part()
    }

    public func send(_ intent: ServerLogsIntent) {
        vm.send(intent: intent)
        part = vm.part()
    }

    /// Loads the list and follows the screen until the calling Task is cancelled.
    public func run() async {
        vm.send(intent: .load)
        part = vm.part()
        let vm = vm
        await observeChanges(from: part.version, changed: { try await vm.changed(seen: $0) }) { _ in
            part = vm.part()
        }
    }
}
