import Observation

/// The `@MainActor @Observable` adapter of `SettingsVm`: sections and rows come ready (German keys
/// translated by the core), writes go through `setSwitch`/`setChoice` and are validated there.
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var sections: SettingsSections
    public private(set) var status: SettingsStatus

    @ObservationIgnored private let vm: SettingsVm
    @ObservationIgnored private let seen: UInt64

    public init(vm: SettingsVm) {
        self.vm = vm
        self.seen = vm.version()
        self.sections = vm.sections()
        self.status = vm.status()
    }

    /// Throws when the row is unknown, hidden or dimmed.
    public func setSwitch(_ key: String, _ on: Bool) throws { try vm.send(intent: .setSwitch(key: key, on: on)) }
    /// Throws when the value is not one of the row's options.
    public func setChoice(_ key: String, _ value: String) throws { try vm.send(intent: .setChoice(key: key, value: value)) }
    public func confirmDisableDownloads(delete: Bool) throws { try vm.send(intent: .confirmDisableDownloads(delete: delete)) }
    public func cancelConfirm() throws { try vm.send(intent: .cancelConfirm) }
    /// New host facts (server, capabilities, stored downloads ...).
    public func facts(_ facts: SettingsFacts) throws { try vm.send(intent: .facts(facts: facts)) }
    /// The store changed from outside.
    public func reload() throws { try vm.send(intent: .reload) }
    /// Work for the host (sync a key, switch the download manager, delete downloads).
    public func takeEffects() -> [SettingsEffectOut] { vm.takeEffects() }

    public func observe() async {
        let sectionsBit = partSettingsSections()
        let statusBit = partSettingsStatus()
        let vm = vm
        await observeChanges(from: seen, changed: { try await vm.changed(seen: $0) }) { change in
            if change.parts & sectionsBit != 0 { sections = vm.sections() }
            if change.parts & statusBit != 0 { status = vm.status() }
        }
    }
}
