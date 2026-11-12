import Observation

/// The shape of the generated `@MainActor @Observable` view-model adapter (ARCHITECTURE.md D3):
/// a loop over `changed(seen:)` that re-reads the state and hands it to SwiftUI. Views read only
/// this class. Cancelling `observe()` (a SwiftUI `.task` going away) drops the Rust future.
@MainActor
@Observable
public final class HelloModel {
    public private(set) var state: HelloState
    private let vm: HelloVm
    private var seen: UInt64

    public init(vm: HelloVm) {
        self.vm = vm
        self.state = vm.state()
        self.seen = vm.version()
    }

    public func send(_ intent: HelloIntent) {
        vm.send(intent: intent)
    }

    /// Returns when the calling Task is cancelled.
    public func observe() async {
        while !Task.isCancelled {
            do {
                let change = try await vm.changed(seen: seen)
                seen = change.version
                state = vm.state()
            } catch {
                return  // cancelled, or the view model is gone
            }
        }
    }
}
