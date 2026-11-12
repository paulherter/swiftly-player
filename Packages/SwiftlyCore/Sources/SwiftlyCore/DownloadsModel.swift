import Foundation
import Observation

/// The `@MainActor @Observable` adapter of `DownloadsVm`. The transfer layer (`DownloadHost`)
/// answers by sending the matching intent from its own task, never from inside the call.
@MainActor
@Observable
public final class DownloadsModel {
    public private(set) var list: ListPart
    public private(set) var storage: StoragePart

    @ObservationIgnored private let vm: DownloadsVm
    @ObservationIgnored private let seen: UInt64
    /// Called on the main actor after every change that came in through `observe` (the transfer
    /// layer's events, the clock), so an owner that keeps a copy of the whole items can refresh it.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(vm: DownloadsVm) {
        self.vm = vm
        self.seen = vm.version()
        self.list = vm.list()
        self.storage = vm.storage()
    }

    /// Throws when the title is unknown or in a state the intent does not fit.
    public func send(_ intent: DownloadsIntent) throws { try vm.send(intent: intent) }

    /// The signed-in account's whole items as the list file's JSON array (German keys), the running
    /// progress merged in.
    public func itemsJson() -> Data { vm.itemsJson() }
    /// Offline playback the server has not seen, as the pending-report list JSON; call it after a
    /// `serverFollow`. Merge it with ``PendingProgress/merged(unreportedJson:into:)``.
    public func unreportedProgressJson(account: String, states: [DownloadWatchState]) -> String {
        vm.unreportedProgressJson(account: account, states: states)
    }
    /// The file name of a finished title, or `nil`.
    public func fileFor(_ id: String) -> String? { vm.fileFor(id: id) }
    /// What a download of `bytes` costs against the last measured free space.
    public func inquiry(bytes: Int64) -> DownloadSpace { vm.inquiry(bytes: bytes) }

    public func observe() async {
        let listBit = partDownloadsList()
        let storageBit = partDownloadsStorage()
        let vm = vm
        await observeChanges(from: seen, changed: { try await vm.changed(seen: $0) }) { change in
            if change.parts & listBit != 0 { list = vm.list() }
            if change.parts & storageBit != 0 { storage = vm.storage() }
            onChange?()
        }
    }
}
