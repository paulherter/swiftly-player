import JellyfinKit
import SwiftlyCore
import SwiftUI

// **The player menus' model side**: which menu is open (`PlayerMenuSession`), what the host gives the core (`PlayerMenuHost`)
// and the conversion of the core's pages into `MenuLevelSpec`s (`PlayerMenuSpecs`). Shared by iPhone/iPad and Apple TV;
// the core builds every level, this file owns no list of options.

/// `folgen` is the episode box (episodes, or the chapters of a film): content the host draws, but it is a menu of this session like
/// the others, so one menu turns into it (and back) with the same box motion.
enum PlayerMenuKind: Hashable { case tracks, settings, seasons, handoff, folgen }

/// What the host does for the menus; set by `PlayerMenuLayer` on every draw.
struct PlayerMenuHost {
    var inputs: () -> PlayerMenusInputs = {
        PlayerMenusInputs(decimalSeparator: ".", techBadge: false, group: nil, look: SubtitleLook.standard.info, seasons: [],
                          shownSeason: nil, handoff: .devices(devices: []), airplay: false)
    }
    var perform: (PlayerMenuAction) -> Void = { _ in }
    /// A quality choice: the screen files it and reloads at the position.
    var quality: (Int64?) -> Void = { _ in }
    /// The host's sleep timer (it pauses and says so).
    var sleep: (UInt32?) -> Void = { _ in }
    var sleepEndOfEpisode: () -> Void = {}
    var fill: (Bool) -> Void = { _ in }
    /// After any player action: what the core asked of the screen (reload for a subtitle, a quality switch).
    var afterPlayerAction: () -> Void = {}
}

/// Which menu is mounted and whether it is open. Closing keeps it mounted for the 140 ms of the close motion.
@Observable @MainActor
final class PlayerMenuSession {
    private(set) var kind: PlayerMenuKind?
    private(set) var isOpen = false
    let navigator = MenuNavigator()
    private(set) var model: PlayerMenusModel?
    /// The open tab of "Ton & Untertitel" and of "Zeit anpassen".
    var tab: PlayerMenuTrackTab = .subtitles
    /// The tab the episode box (`.folgen`) opened at: Folgen for a series, Kapitel for a film.
    private(set) var panelTab: PlayerMenuPanelTab = .episodes
    /// The session id of the device the title is being handed to.
    var handoffBusy: String?
    @ObservationIgnored var host = PlayerMenuHost()
    @ObservationIgnored private var player: PlayerModel?
    @ObservationIgnored private var levels: [String: PlayerMenuLevel] = [:]
    @ObservationIgnored private var closing: Task<Void, Never>?

    /// The model exists as soon as the player's core does (also for the season button of the episodes panel).
    func prepare(player new: PlayerModel?) {
        guard let new else { return }
        if player !== new {
            player = new
            model = PlayerMenusModel(player: new, inputs: { [unowned self] in self.host.inputs() },
                                     perform: { [unowned self] in self.host.perform($0) })
        }
    }

    func open(_ new: PlayerMenuKind, player: PlayerModel? = nil, panel: PlayerMenuPanelTab = .episodes) {
        closing?.cancel()
        prepare(player: player)
        // Another button while a box is open: the box moves to it and the content cross-fades (one tap, no close first).
        let switching = isOpen && kind != nil && kind != new
        let change = {
            if self.kind != new { self.navigator.reset(); self.levels = [:]; self.tab = .subtitles }
            self.panelTab = panel
            self.model?.open(Self.root(new, panel: panel))
            self.kind = new
            self.isOpen = true
        }
        if switching { withAnimation(Motion.menuSwitch) { change() } } else { change() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        model?.close()
        closing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, !self.isOpen else { return }
            self.kind = nil
            self.navigator.reset()
            self.levels = [:]
        }
    }

    static func root(_ kind: PlayerMenuKind, panel: PlayerMenuPanelTab = .episodes) -> PlayerMenuLevel {
        switch kind {
        case .tracks: .tracks(tab: .subtitles)
        case .settings: .options
        case .seasons: .seasons
        case .handoff: .handoff
        case .folgen: .episodes(tab: panel)
        }
    }

    func level(_ id: String) -> PlayerMenuLevel? { levels[id] }

    func back() { navigator.pop(); model?.back() }

    /// Every press of every row.
    func press(_ action: PlayerMenuAction) {
        guard let model else { return }
        switch action {
        case let .open(level):
            if case let .timeAdjust(tab: target) = level { tab = target }
            if case let .tracks(tab: target) = level { tab = target }
            let id = String(describing: level)
            levels[id] = level
            navigator.push(id)
            model.press(action)
        case let .player(intent):
            switch intent {
            case let .quality(limit): host.quality(limit)
            case let .sleep(minutes): model.press(action); host.sleep(minutes)
            case .sleepEndOfEpisode: model.press(action); host.sleepEndOfEpisode()
            case let .fill(on): model.press(action); host.fill(on)
            default: model.press(action)
            }
            host.afterPlayerAction()
        default:
            model.press(action)
        }
    }
}


// MARK: - Core page -> level data

/// A level's data and the core action behind each row id.
struct PlayerMenuBuilt {
    var spec: MenuLevelSpec
    var actions: [String: PlayerMenuAction] = [:]
}

/// Turns the core's pages into `MenuLevelSpec`s. Decides nothing: order, words and selection come from the core.
struct PlayerMenuSpecs {
    let menus: PlayerMenus
    let tab: PlayerMenuTrackTab
    /// "Problem melden" only for an account that may report.
    let canReport: Bool
    /// "Sperren" swallows touches: a device with a pointer and keys has nothing to lock.
    var canLock = true

    func build(_ level: PlayerMenuLevel, isRoot: Bool) -> PlayerMenuBuilt {
        var out = PlayerMenuBuilt(spec: MenuLevelSpec(id: String(describing: level)))
        var n = 0
        func key(_ action: PlayerMenuAction) -> String { n += 1; let id = "a\(n)"; out.actions[id] = action; return id }
        func back(_ title: String) -> String? { isRoot ? nil : title }

        switch level {
        case .options:
            // Design: Geschwindigkeit, Schlafzeit | Bild, Qualität | Gemeinsam schauen, divided by a line after Schlafzeit and Qualität.
            out.spec.rows = menus.options.rows.flatMap { row -> [MenuRowSpec] in
                let line: Bool = {
                    if case .open(let level) = row.action, level == .sleep || level == .quality { return true } else { return false }
                }()
                let made = MenuRowSpec.value(id: key(row.action), label: row.title.text, value: row.value.text)
                return line ? [made, .divider] : [made]
            }
            out.spec.footer = menus.options.footer.compactMap { row in
                if case .reportProblem = row.action, !canReport { return nil }
                if case .lockScreen = row.action, !canLock { return nil }
                let report: Bool = { if case .reportProblem = row.action { return true } else { return false } }()
                // The phone's footer says "Sperren" (design); the core's longer "Bildschirm sperren" is the row text of the big screens.
                let lock: Bool = { if case .lockScreen = row.action { return true } else { return false } }()
                return MenuFooterButton(id: key(row.action), label: lock ? String(localized: "Sperren") : row.title.text,
                                        symbol: report ? "exclamationmark.triangle" : "lock", quiet: report)
            }
        case .speed:
            out.spec.backTitle = back(menus.speed.title.text)
            out.spec.rows = menus.speed.choices.map { check($0, key) }
        case .picture:
            out.spec.backTitle = back(menus.picture.title.text)
            out.spec.rows = menus.picture.choices.map { check($0, key) }
        case .sleep:
            let page = menus.sleep
            out.spec.backTitle = back(page.title.text)
            out.spec.rows = page.choices.map { check($0, key) } + [
                .capsules(id: "minutes", caption: page.minutesTitle.text, items: capsules(page.minutes, "minutes", &out),
                          selected: page.minutes.firstIndex(where: \.selected).map(String.init)),
            ]
        case .quality:
            let page = menus.quality
            out.spec.backTitle = back(page.title.text)
            if page.offered {
                out.spec.rows = [check(page.original, key),
                                 .capsules(id: "bitrate", caption: page.bitrateTitle.text, items: capsules(page.bitrates, "bitrate", &out),
                                           selected: page.bitrates.firstIndex(where: \.selected).map(String.init))]
            }
            out.spec.fixedRows = [.toggle(id: key(page.badgeAction), label: page.badgeTitle.text, isOn: page.badgeOn)]
        case .together:
            guard let page = menus.together else { break }
            out.spec.backTitle = back(page.groupName)
            out.spec.rows = page.members.map { .person(name: $0.name, status: $0.status.text) }
            out.spec.fixedRows = [.action(id: key(page.leave.action), label: page.leave.title.text,
                                          symbol: "rectangle.portrait.and.arrow.right", destructive: true)]
        case .tracks:
            let page = menus.tracks
            let subtitles = tab == .subtitles
            let tabPage = subtitles ? page.subtitles : page.audio
            out.spec.rows = tabPage.rows.map {
                .check(id: key($0.action), label: $0.labelIsKey ? PlayerMenuWords.key(key: $0.label).text : $0.label, selected: $0.selected)
            }
            // **The bar is up before the stream answers**, so this menu can open too: with no audio track known yet, a quiet
            // line says the rows are coming (the same spec rebuilds when the tracks arrive).
            if page.audio.rows.isEmpty { out.spec.rows.append(.hint(String(localized: "Spuren werden geladen …"))) }
            let items = page.tabs.map { MenuCapsule(id: Self.tabID($0), label: ($0 == .subtitles ? page.subtitles : page.audio).title.text) }
            var segments = MenuSegmentsSpec(items: items, selected: Self.tabID(tab))
            if subtitles, let search = page.subtitles.search { out.actions["search"] = search; segments.search = true }
            out.spec.segments = segments
            let time = subtitles ? page.subtitleTime : page.audioTime
            out.spec.fixedRows = [.value(id: key(time.action), label: time.title.text, value: time.value.text)]
            if subtitles {
                out.spec.fixedRows.append(.value(id: key(page.look.action), label: page.look.title.text, value: page.look.value.text))
            }
        case .subtitleLook:
            out.spec.backTitle = back(menus.look.title.text)
            out.spec.rows = menus.look.groups.enumerated().map { index, group in
                for (j, choice) in group.choices.enumerated() { out.actions["g\(index):\(j)"] = choice.action }
                return .capsules(id: "g\(index)", caption: group.title.text,
                                 items: group.choices.enumerated().map { MenuCapsule(id: "\($0.offset)", label: $0.element.label.text) },
                                 selected: group.choices.firstIndex(where: \.selected).map(String.init), compact: true)
            }
        case .timeAdjust:
            let page = menus.time
            out.spec.backTitle = back(page.title.text)
            let items = page.tabs.map { MenuCapsule(id: Self.tabID($0.tab), label: $0.title.text) }
            out.spec.segments = MenuSegmentsSpec(items: items, selected: Self.tabID(tab))
            if let t = page.tabs.first(where: { $0.tab == tab }) ?? page.tabs.first {
                out.actions["earlier"] = t.earlier.action
                out.actions["later"] = t.later.action
                if let reset = t.reset { out.actions["reset"] = reset.action }
                out.spec.step = MenuStepSpec(value: t.value, caption: t.meaning.text, earlierLabel: t.earlier.title.text,
                                             laterLabel: t.later.title.text, earlierMs: -1, laterMs: 1,
                                             resetLabel: t.reset?.title.text ?? "", canReset: t.reset != nil)
            }
        case .seasons, .episodes:
            let page = menus.episodes
            out.spec.rows = page.seasons.map { check($0, key) }
        case .handoff:
            let page = menus.handoff
            out.spec.rows = [.section(page.title.text)]
            switch page.state {
            case .list:
                let devices = page.rows + (page.airplay.map { [$0] } ?? [])
                for row in devices {
                    let isAirPlay: Bool = { if case .airPlay = row.action { return true } else { return false } }()
                    out.spec.rows.append(.device(id: key(row.action), name: row.name, kind: row.detail ?? "", loading: row.busy,
                                                 enabled: row.enabled, symbol: isAirPlay ? "airplayvideo" : "tv"))
                }
            case .loading, .empty:
                if let text = page.text { out.spec.rows.append(.hint(text.text)) }
            }
            out.spec.rows.append(.divider)
            out.spec.rows.append(.hint(page.note.text))
        }
        return out
    }

    private func check(_ choice: PlayerMenuChoice, _ key: (PlayerMenuAction) -> String) -> MenuRowSpec {
        .check(id: key(choice.action), label: choice.label.text, detail: choice.detail?.text, selected: choice.selected)
    }

    private func capsules(_ choices: [PlayerMenuChoice], _ group: String, _ out: inout PlayerMenuBuilt) -> [MenuCapsule] {
        for (j, choice) in choices.enumerated() { out.actions["\(group):\(j)"] = choice.action }
        return choices.enumerated().map { MenuCapsule(id: "\($0.offset)", label: Self.number($0.element.label)) }
    }

    /// A capsule shows the bare number ("15", "40"); the unit sits in the caption.
    private static func number(_ words: PlayerMenuWords) -> String {
        if case let .count(_, count) = words { return String(count) }
        return words.text
    }

    static func tabID(_ tab: PlayerMenuTrackTab) -> String { tab == .subtitles ? "subtitles" : "audio" }
}

extension SubtitleLook {
    var info: SubtitleLookInfo {
        SubtitleLookInfo(
            background: background,
            colour: { switch colour { case .white: .white; case .yellow: .yellow; case .grey: .grey } }(),
            keepFileStyle: keepFileStyle,
            outline: { switch outline { case .off: .off; case .thin: .thin; case .normal: .normal } }(),
            position: position == .raised ? .raised : .bottom,
            shadow: shadow,
            size: { switch size { case .small: .small; case .normal: .normal; case .large: .large; case .huge: .huge } }())
    }

    init(_ info: SubtitleLookInfo) {
        self.init(size: { switch info.size { case .small: .small; case .normal: .normal; case .large: .large; case .huge: .huge } }(),
                  colour: { switch info.colour { case .white: .white; case .yellow: .yellow; case .grey: .grey } }(),
                  outline: { switch info.outline { case .off: .off; case .thin: .thin; case .normal: .normal } }(),
                  shadow: info.shadow, background: info.background,
                  position: info.position == .raised ? .raised : .bottom, keepFileStyle: info.keepFileStyle)
    }
}

/// The seasons of the running series and the open one: shared by the episodes panel and the menus' inputs; a choice
/// from the season box lands in `chosen` and the panel switches.
@Observable @MainActor
final class SeasonPicker {
    var seasons: [Item] = []
    var selected: Item?
    var chosen: String?

    /// The panel's init runs on every re-evaluation of the screen (it re-reads the cache): it may fill the seasons, but a
    /// season the viewer already chose must stay. Before, the tvOS init reset `selected` to the rule's season each time
    /// the season box closed, so the choice was dropped before its episodes arrived.
    func adopt(seasons new: [Item], rule: Item?) {
        seasons = new
        if let current = selected?.id, new.contains(where: { $0.id == current }) { return }
        selected = rule
    }

    /// A choice from the season box (`chosen`): consumes it and returns the season to switch to, `nil` when there is
    /// nothing to do (unknown id, or already open). The caller then loads that season's episodes.
    func takeChoice(_ id: String?) -> Item? {
        AppLog.writeOut("[Staffel] panel sees choice \(id ?? "-") of \(seasons.count) seasons, open \(selected?.id ?? "-")")
        guard let id, let season = seasons.first(where: { $0.id == id }) else { return nil }
        chosen = nil
        guard season.id != selected?.id else { return nil }
        selected = season
        return season
    }
}
