import Foundation
import JellyfinKit
import Observation
import SwiftUI
import SwiftlyCore

/// The Seerr title screens' host side: colours for the core's badge kinds, identity for the core's records,
/// and ``SeerrTitleFlow``, the one object the series page, the not-on-server page and the request sheet share.
/// The words, the states and the quota all come from the core; this file only keeps what the core returned.
extension SwiftlyCore.BadgeKind {
    /// **Three colours, as in `SeerrMark.swift`**: `warning` where someone has to act, `accent` for anything
    /// on its way, `fontQuiet` for the calm cases; `error` for what did not work.
    var tint: Color {
        switch self {
        case .requestable, .blocked: Theme.fontQuiet
        case .waits: Theme.warning
        case .searching, .soon, .fetching, .partial: Theme.accent
        case .available: Theme.font
        case .declined, .failed: Theme.error
        }
    }
}

extension SwiftlyCore.SeerrChoiceOption: @retroactive Identifiable {}
extension SwiftlyCore.SeerrSeasonRowInfo: @retroactive Identifiable {
    public var id: Int64 { number }
}
extension SwiftlyCore.SeerrEpisodeInfo: @retroactive Identifiable {
    public var id: Int64 { number }
}
extension SwiftlyCore.SeerrTileCard: @retroactive Identifiable {
    public var id: String { "\(art)-\(tmdb)" }

    /// The page a tile opens (the app's route type for "a title the own server does not have").
    var route: JellyfinKit.SeerrHit {
        JellyfinKit.SeerrHit(id: Int(tmdb), art: art, title: title, year: year.map(Int.init),
                             posterPath: nil, backdropPath: nil, state: .opened)
    }
}

extension SwiftlyCore.SeerrHub {
    /// Seerr is connected and its session works. Reads the account once when the hub has not yet; the screens
    /// draw nothing at all while this is false.
    func ready() async -> Bool {
        // The account only (one single-flight read); the screens that show counts read them next to their lists.
        (try? await ensureAvailable()) ?? false
    }
}

/// **Seerr's answer for a series, asked ahead and kept per title.** When a series tile is pressed (the same moment the
/// core warms the series) its Seerr page is loaded in the background, so the season menu's rows are there when the
/// page opens. The chevron does not wait for it (it is the core's rule, `SeasonsPart.chevron`); this only fills the menu.
@MainActor
enum SeerrTitleWarm {
    private static var flows: [Int64: SeerrTitleFlow] = [:]
    private static var order: [Int64] = []

    /// Starts (once per title) the load of the title's Seerr page.
    static func warm(hub: SwiftlyCore.SeerrHub, tmdb: Int64) {
        guard flows[tmdb] == nil else { return }
        let flow = SeerrTitleFlow(hub: hub, art: "tv", tmdb: tmdb)
        flows[tmdb] = flow
        order.append(tmdb)
        if order.count > 8 { flows[order.removeFirst()] = nil }
        Task { await flow.start() }
    }

    /// The warmed flow of the title, if there is one.
    static func flow(tmdb: Int64) -> SeerrTitleFlow? { flows[tmdb] }
}

/// **One title at Seerr, as the pages show it.** Wraps the core's `SeerrTitleScreen` and keeps the last
/// records, so a view just reads them. Intents go to the core, whose answer replaces the records.
@MainActor
@Observable
final class SeerrTitleFlow {
    @ObservationIgnored let hub: SwiftlyCore.SeerrHub
    @ObservationIgnored let screen: SwiftlyCore.SeerrTitleScreen
    @ObservationIgnored let lists: SwiftlyCore.SeerrListsScreen
    let art: String
    let tmdb: Int64

    private(set) var info: SwiftlyCore.SeerrTitleInfo
    /// What the request sheet shows. **Never changes while the card slides out** (see ``setSheet(_:)``).
    private(set) var sheet: SwiftlyCore.SeerrSheetInfo
    /// The card is on its way out: a new record waits here until it is gone.
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var waiting: SwiftlyCore.SeerrSheetInfo?
    /// The season chooser's rows (library seasons normal, the others grey), once the page loaded.
    private(set) var picker: [SwiftlyCore.SeerrSeasonRowInfo] = []
    /// Titles like this one that are not on the server.
    private(set) var similar: [SwiftlyCore.SeerrTileCard] = []
    /// Seerr answered (connected, session valid). Before that every screen draws nothing.
    private(set) var ready = false
    /// The quota line of the account for this kind of title ("Noch 1 von 3 Staffeln frei diese Woche").
    private(set) var quota: String?
    var sheetOpen = false
    /// The seasons that list episodes: the chips of the page's "Folgen" block.
    private(set) var episodeSeasons: [SwiftlyCore.SeerrSeasonRowInfo] = []
    /// The season whose episodes show. **The core's rule** (`SeerrTitleScreen.episodeSeason`, the same one the desktop
    /// uses) applied to the person's pick; only the pick itself is kept here.
    private(set) var episodeSeason: Int64?
    @ObservationIgnored private var episodePicked: Int64?
    /// Returns once the page may take new content. A page that slides in (macOS) waits here until it has settled, so the
    /// answer does not rebuild the page in the middle of the motion. The fetch itself starts at once; only applying waits.
    @ObservationIgnored var settle: @MainActor () async -> Void = {}

    /// The row of ``episodeSeason``.
    var episodeSeasonRow: SwiftlyCore.SeerrSeasonRowInfo? {
        episodeSeasons.first { $0.number == episodeSeason }
    }

    init(hub: SwiftlyCore.SeerrHub, art: String, tmdb: Int64) {
        self.hub = hub
        self.art = art
        self.tmdb = tmdb
        let made = SwiftlyCore.SeerrTitleScreen(hub: hub, art: art, tmdb: tmdb)
        screen = made
        lists = SwiftlyCore.SeerrListsScreen(hub: hub)
        let first = made.info()
        info = first
        sheet = first.sheet
    }

    /// Opens the page's data. `library` are the season numbers the own server has (series).
    func start(library: [Int64]? = nil) async {
        // **Not tied to the caller's task.** A page's `.task(id:)` restarts when its key changes (the seasons
        // arrive); a cancelled load would leave the page without its seasons and similar titles for good.
        await Task { @MainActor in
            guard await hub.ready() else { return }
            ready = true
            if let library { screen.setLibrarySeasons(numbers: library) }
            _ = try? await screen.load()
            await settle()
            pull()
            // The similar titles never hold up the page.
            let more = (try? await lists.similar(art: art, tmdb: tmdb)) ?? []
            await settle()
            similar = more
        }.value
    }

    /// The own server's seasons changed (a scan found one).
    func setLibrary(_ numbers: [Int64]) {
        guard ready else { return }
        screen.setLibrarySeasons(numbers: numbers)
        pull()
    }

    /// A chip of the "Folgen" block was chosen.
    func pickEpisodeSeason(_ number: Int64) {
        episodePicked = number
        episodeSeason = screen.episodeSeason(picked: number)
    }

    private func pull() {
        info = screen.info()
        episodeSeasons = info.seasons.filter { !$0.episodeList.isEmpty }
        episodeSeason = screen.episodeSeason(picked: episodePicked)
        picker = screen.seasonPicker()
        setSheet(info.sheet)
        quota = hub.quotaLine(art: art)
    }

    // MARK: Request sheet

    /// The sheet opens at once with what the core has; the quota line and the admin choices arrive a moment
    /// later and fill reserved space.
    func open(season: Int64?) {
        closing = false
        waiting = nil
        sheet = screen.openSheet(season: season)
        sheetOpen = true
        Task {
            // **The answer goes in without an animation.** Every row already stands at its final size
            // (reserved by `openSheet`); only values fill in. Put in with `withAnimation(sheetMotion)`,
            // the answer landed in the ~40 ms before the card starts to rise, and SwiftUI re-laid the
            // card's content out in that spring: everything below the 4K row started up to 120 pt too low
            // and caught up while the card rose (measured: Werkzeuge/sheet-ride-check.py --ref).
            if let loaded = try? await screen.loadSheet() {
                if closing { waiting = loaded } else {
                    var plain = Transaction()
                    plain.disablesAnimations = true
                    withTransaction(plain) { sheet = loaded }
                }
            }
        }
    }

    func close() {
        sheetOpen = false
        endSheet(screen.closeSheet())
    }

    /// **The card keeps what it shows until it is gone.** The reset to the closed record (and the refresh
    /// after a request) used to change the card's content in the very moment it started to slide out: the
    /// card got shorter or taller under its own motion and its top edge jumped before it left. The core is
    /// reset at once; the picture follows once the slide-out is over.
    private func endSheet(_ next: SwiftlyCore.SeerrSheetInfo) {
        closing = true
        waiting = next
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard closing else { return }
            closing = false
            if let waiting { var plain = Transaction(); plain.disablesAnimations = true
                withTransaction(plain) { sheet = waiting } }
            waiting = nil
        }
    }

    /// A record from the core: shown now, or after the slide-out while the card is leaving.
    private func setSheet(_ next: SwiftlyCore.SeerrSheetInfo) {
        if closing { waiting = next } else { sheet = next }
    }

    func toggle(_ number: Int64) { sheet = screen.toggle(number: number) }
    func setFourK(_ on: Bool) { sheet = screen.setFourK(on: on) }
    func chooseQuality(_ id: String) { if let n = Int64(id) { sheet = screen.chooseQuality(id: n) } }
    func chooseFolder(_ path: String) { sheet = screen.chooseFolder(path: path) }

    /// Sends the request. The sheet closes when Seerr took it (or knew it already); an error stays in the
    /// sheet with its text.
    func confirm() async {
        let watch = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if !Task.isCancelled { sheet = screen.info().sheet }
        }
        let result = try? await screen.confirm()
        watch.cancel()
        switch result {
        case .requested, .exists:
            sheetOpen = false
            endSheet(screen.info().sheet)
            _ = try? await screen.refresh()
            _ = try? await hub.refresh()
            pull()
        case .notSent, .failed, .none:
            setSheet(screen.info().sheet)
        }
    }

    /// After something changed elsewhere (an admin decision).
    func reload() async {
        _ = try? await screen.refresh()
        pull()
    }
}

/// A tile of a title the own server does not have (the core's record, named once for the views that do not
/// import the core).
typealias SeerrCard = SwiftlyCore.SeerrTileCard

extension SeerrModel {
    /// What a person did that is not on the server; empty without Seerr.
    func personCards(tmdb: Int64) async -> [SeerrCard] {
        guard connected, await hub.ready() else { return [] }
        return (try? await SwiftlyCore.SeerrListsScreen(hub: hub).personCredits(tmdb: tmdb)) ?? []
    }

    /// The parts of a collection that are not on the server; empty without Seerr.
    func collectionCards(tmdb: Int64) async -> [SeerrCard] {
        guard connected, await hub.ready() else { return [] }
        return (try? await SwiftlyCore.SeerrListsScreen(hub: hub).collectionParts(id: tmdb)) ?? []
    }
}
