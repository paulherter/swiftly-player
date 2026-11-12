import Foundation
import JellyfinKit
import Observation
import SwiftUI
import SwiftlyCore

/// **Settings rows from the Rust core** (`SettingsModel` over `SettingsVm`): sections, rows, titles,
/// dimming, validation and the "turn Downloads off" question come from the core; the views keep
/// their look and only ask this feed for the row of a key.
///
/// Values stay in the same `UserDefaults` keys and types (`UserDefaultsSettingsStore`), so every
/// `@AppStorage` reader sees what the core writes. The other direction, and the in-memory copies
/// `AppModel` keeps of many keys:
/// - a write through the core is adopted into `AppModel` at once (`adopt`), with its old `didSet`
///   side effects (download manager, subtitle "automatic");
/// - any other change of `UserDefaults` (an `@AppStorage` view, settings sync) reloads the core.
/// Adopting only assigns a value that differs, and a reload writes nothing, so neither can loop.
@MainActor
@Observable
final class SettingsRowsFeed {
    /// One per process: the pages share it, each hands over its own facts when it appears.
    static let shared = SettingsRowsFeed()

    let core: SwiftlyCore.SettingsModel
    @ObservationIgnored private let store = UserDefaultsSettingsStore()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var facts: SwiftlyCore.SettingsFacts
    @ObservationIgnored private var observing: [Task<Void, Never>] = []
    @ObservationIgnored private var reloadQueued = false

    private init() {
        let first = Self.blank
        facts = first
        core = SwiftlyCore.SettingsModel(
            vm: AppCore.shared.raw.settingsVmNative(
                store: store, locale: AppCore.language, facts: first))
        observing.append(Task { [core] in await core.observe() })
        observing.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.outsideChange()
            }
        })
    }

    private static var blank: SwiftlyCore.SettingsFacts {
        SwiftlyCore.SettingsFacts(
            platform: platform, seerr: false, settingsSync: false, downloads: platform != .tv, server: "",
            canConvert: true, watchersPlugin: false, landscapeLockPossible: false,
            seerrConnected: false, ownHeaders: 0, subtitleLookSummary: "", storedDownloads: 0,
            storedBytes: 0, accountNextAuto: nil)
    }

    private static var platform: SwiftlyCore.SettingsPlatform {
        #if os(tvOS)
        .tv
        #elseif os(macOS)
        .desktop
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        #endif
    }

    // MARK: Facts

    /// What the core needs from the app; read it in a view body so a change re-hands it
    /// (`.onChange(of: feed.facts(model), initial: true) { feed.apply($0, model) }`).
    func facts(_ model: AppModel) -> SwiftlyCore.SettingsFacts {
        let allocation = DownloadRules.allocation(model.downloads.entries)
        #if os(iOS)
        let landscape = Orientierung.landscapeLockPossible
        #else
        let landscape = false
        #endif
        return SwiftlyCore.SettingsFacts(
            platform: Self.platform, seerr: model.can(.seerr), settingsSync: model.can(.settingsSync),
            downloads: Self.platform != .tv, server: model.session?.serverSuffix ?? "", canConvert: model.convertAllowed,
            watchersPlugin: model.watchersPluginHere, landscapeLockPossible: landscape,
            seerrConnected: model.seerr.connected,
            ownHeaders: UInt32(model.ownHeaders(for: model.session?.serverURL).count),
            subtitleLookSummary: model.subtitleLook.entryValue,
            storedDownloads: UInt32(model.downloads.entries.count), storedBytes: Int64(allocation.bytes),
            accountNextAuto: model.nextAutomaticAccount)
    }

    func apply(_ new: SwiftlyCore.SettingsFacts, _ model: AppModel) {
        app = model
        guard new != facts else { return }
        facts = new
        try? core.facts(new)
    }

    // MARK: Rows

    func row(_ key: String) -> SwiftlyCore.SettingsRow? {
        for section in core.sections.sections {
            if let hit = section.rows.first(where: { $0.key == key }) { return hit }
        }
        return nil
    }

    func section(_ titleKey: String) -> SwiftlyCore.SettingsSection? {
        core.sections.sections.first { $0.titleKey == titleKey }
    }

    func isOn(_ key: String) -> Bool {
        if case .switch(let on)? = row(key)?.control { return on }
        return false
    }

    /// The title of a row: the core's, or the wording this device has always used
    /// (`SettingsWording`, translated by the app catalog like the old literals).
    func title(_ key: String) -> Text {
        if let own = SettingsWording.entry(Self.platform, key)?.title { return Text(LocalizedStringKey(own)) }
        return row(key)?.titleText ?? Text(verbatim: "")
    }

    /// The same title as a translated string (for rows that take a verbatim name).
    func titleString(_ key: String) -> String {
        if let own = SettingsWording.entry(Self.platform, key)?.title {
            return String(localized: String.LocalizationValue(own))
        }
        return row(key)?.title ?? ""
    }

    /// The second line of a row, with the same device wording.
    func under(_ key: String) -> Text? {
        switch SettingsWording.entry(Self.platform, key)?.under ?? .core {
        case .core: row(key)?.underText
        case .none: nil
        case .text(let own): Text(LocalizedStringKey(own))
        }
    }

    private func shownLabel(_ key: String, _ value: String, _ core: String) -> String {
        guard let own = SettingsWording.entry(Self.platform, key)?.shown[value] else { return core }
        return String(localized: String.LocalizationValue(own))
    }

    /// The value text of a choice, info or link row (what the row shows on its right).
    func shown(_ key: String) -> String? {
        switch row(key)?.control {
        case .choice(let selected, let shown, _)?: shownLabel(key, selected, shown)
        case .info(let value)?: value
        case .link(let value)?: value
        default: nil
        }
    }

    func options(_ key: String) -> [(value: String, label: String, selected: Bool)] {
        guard case .choice(let selected, _, let options)? = row(key)?.control else { return [] }
        return options.map { ($0.value, $0.label, $0.value == selected) }
    }

    /// An option of a choice row, for pages that list it themselves.
    struct Choice: Identifiable {
        let value: String
        let label: String
        let selected: Bool
        var id: String { value }
    }

    func choices(_ key: String) -> [Choice] {
        options(key).map { Choice(value: $0.value, label: $0.label, selected: $0.selected) }
    }

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.isOn(key) }, set: { self.setSwitch(key, $0) })
    }

    // MARK: Writes

    func setSwitch(_ key: String, _ on: Bool) {
        do { try core.setSwitch(key, on) } catch { AppLog.writeOut("[Einstellungen] \(key): \(error)") }
        written()
    }

    func choose(_ key: String, _ value: String) {
        do { try core.setChoice(key, value) } catch { AppLog.writeOut("[Einstellungen] \(key): \(error)") }
        written()
    }

    var asksAboutDownloads: Bool { core.status.confirm == .disableDownloads }

    func answerDisable(delete: Bool) {
        do { try core.confirmDisableDownloads(delete: delete) } catch {}
        written()
    }

    /// The sheet was closed without an answer. Deferred one turn: the sheet closes before its action runs.
    func dismissQuestion() {
        Task { @MainActor in
            if self.asksAboutDownloads { try? self.core.cancelConfirm() }
        }
    }

    private func written() {
        for effect in core.takeEffects() {
            // `changed` needs nothing: settings sync notices the `UserDefaults` write itself.
            if case .deleteDownloads = effect { app?.downloads.allRemove() }
        }
        // No `store.flush()` here: it waits on the store's write queue, and that queue's
        // `UserDefaults.set` delivers `didChangeNotification` to observers that run on the main thread
        // (`@AppStorage`), which is where this runs. Both wait for each other and the app hangs. Reads
        // see the pending write anyway (`UserDefaultsSettingsStore.get`).
        adopt()
    }

    // MARK: Both directions

    private func outsideChange() {
        guard !reloadQueued else { return }
        reloadQueued = true
        Task { @MainActor in
            self.reloadQueued = false
            try? self.core.reload()
        }
    }

    private func bool(_ key: String) -> Bool? {
        if case .bool(let v)? = store.get(key: key) { return v }
        return nil
    }
    private func int(_ key: String) -> Int? {
        if case .int(let v)? = store.get(key: key) { return Int(v) }
        return nil
    }
    private func text(_ key: String) -> String? {
        if case .text(let v)? = store.get(key: key) { return v }
        return nil
    }

    /// Copy the stored values into the model's in-memory properties, only where they differ.
    private func adopt() {
        guard let app else { return }
        let k = app.session?.serverSuffix ?? ""
        func put<T: Equatable>(_ path: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
            if app[keyPath: path] != value { app[keyPath: path] = value }
        }
        put(\.alwaysDirectPlay, bool("immerDirectPlay" + k) ?? bool("immerDirectPlay") ?? true)
        put(\.bitratesLimit, int("bitratenGrenze" + k) ?? int("bitratenGrenze") ?? 0)
        put(\.landscapeFixed, bool("querformatFest") ?? true)
        put(\.progressOnTiles, bool("fortschritt") ?? true)
        put(\.watchlistShown, bool("merklisteAn") ?? true)
        put(\.alphabetShown, bool("alphabetAn") ?? true)
        put(\.watchersShown, bool("gesehenVonAn") ?? true)
        put(\.audioLanguage, text("tonSprache") ?? "")
        put(\.subtitleLanguage, text("utSprache") ?? "")
        put(\.subtitleAutomatic, bool("utAuto") ?? false)
        if let own = bool("naechsteAuto"), app.nextAutomatic != own { app.nextAutomatic = own }
        put(\.newAccessDisconnected, bool("neuGetrennt") ?? true)
        put(\.genreChips, bool("genreChips") ?? false)
        put(\.bufferLevel, text("pufferstufe").flatMap(JellyfinKit.BufferLevel.init(rawValue:)) ?? .normal)
        put(\.backSeconds, int("zurueckSek") ?? 10)
        put(\.forwardSeconds, int("vorSek") ?? 30)
        put(\.downloadsAn, bool("downloadsAn") ?? false)
        put(\.onlyOverWLAN, bool("nurUeberWLAN") ?? true)
        if let sync = bool("einstellungenSync"), app.settingsSync.on != sync { app.settingsSync.on = sync }
        if let next = bool(DownloadManager.nextAutoKey), app.downloads.nextAuto != next {
            app.downloads.nextAuto = next
        }
    }

    // MARK: Symbols (the view's own; the core has no icons)

    static let symbols: [String: String] = [
        "immerDirectPlay": "play", "bitratenGrenze": "speedometer", "tonSprache": "speaker.wave.2",
        "utSprache": "captions.bubble", "utAuto": "text.alignleft", "utAussehen": "textformat.size",
        "naechsteAuto": "forward.end", "introAbspannAuto": "forward", "zurueckSek": "gobackward",
        "vorSek": "goforward", "querformatFest": "rectangle.on.rectangle",
        "technikschild": "waveform.badge.magnifyingglass", "endzeitImPlayer": "clock",
        "fortschritt": "chart.bar", "merklisteAn": "bookmark", "gesehenVonAn": "eye",
        "alphabetAn": "textformat.abc", "titelAlsLogo": "textformat",
        "downloadsAn": "arrow.down.circle", "nurUeberWLAN": "wifi",
        "naechsteFolgeLaden": "play.square.stack", "downloadsSpeicher": "internaldrive",
        "eigeneHeader": "key", "seerr": "sparkle.magnifyingglass",
        "einstellungenSync": "arrow.triangle.2.circlepath",
    ]

    static func symbol(_ key: String) -> String { symbols[key] ?? "gearshape" }
}

extension SwiftlyCore.SettingsRow {
    /// The title as the core translated it (a verbatim `Text`: the core already localized it).
    var titleText: Text { Text(verbatim: title) }
    var underText: Text? { under.map { Text(verbatim: $0) } }
}
