import Foundation
import JellyfinKit
import SwiftUI

#if canImport(SwiftlyCore)
import SwiftlyCore

/// **The movie/episode page's data owner: the core's `DetailVm`.**
///
/// The screens (iPhone and iPad, Apple TV, Mac) draw what the model's parts say (hero, play button, toggles, proof
/// row, cast, extras, similar, collections, watchers, file excerpt) and send intents back; which button state,
/// which versions, which menu entries, what a press on Play does and what a toggle writes is decided in the core.
/// What stays here is what only the platform can do: the `Item` the player and the download sheet are handed
/// (decoded from the core's own title JSON), the options the core cannot know (settings, devices, rights), and
/// the effects it queues for the host (open a trailer page, hand a title to another device, ...).
@MainActor
@Observable
final class DetailCore {
    let model: SwiftlyCore.DetailModel

    @ObservationIgnored private var cached: (key: UInt64, item: Item)?
    /// The list entry the page was opened with.
    @ObservationIgnored let listItem: Item

    /// `nil` when the core cannot serve this session (no account).
    init?(app: AppModel, item: Item) {
        guard let model = try? app.core.detail(session: app.session, tile: SwiftlyCore.Tile(standIn: item)) else {
            return nil
        }
        self.model = model
        self.listItem = item
        // The options (viewers row, download field) are known before frame 1, so the rows they decide are in place at once.
        send(options: app)
    }

    // MARK: The title

    /// The title as the player, the download sheet and the tile menu take it: the core's fresh copy (else the
    /// stored one, else the list entry), decoded once per change of the page.
    var item: Item {
        let key = model.hero.version &+ (model.actions.version << 20)
        if let cached, cached.key == key { return cached.item }
        let fresh =
            model.itemJSON().flatMap { try? JSONDecoder().decode(Item.self, from: Data($0.utf8)) } ?? listItem
        cached = (key, fresh)
        return fresh
    }

    /// The title's own plan, if the core holds one; saves the request on press.
    func plan(app: AppModel) -> PlaybackPlan? {
        PlaybackPlan.core(model.planAnswer(), itemID: model.hero.id, app: app)
    }

    // MARK: Host knowledge

    #if os(iOS) || os(macOS)
    static let canOpenWeb = true
    #else
    static let canOpenWeb = false
    #endif

    /// The other devices a title can be handed to, as the core wants them.
    static func playOnDevices(_ app: AppModel) -> [SwiftlyCore.PlayOnDevice] {
        app.can(.playOnOtherDevice)
            ? PlayOutputs.shared.targets.compactMap(PlayOutput.init(session:)).map {
                SwiftlyCore.PlayOnDevice(id: $0.deviceID, name: $0.name)
            } : []
    }

    /// What the core cannot know: settings, rights, devices in reach. Sent again whenever one changes.
    func send(options app: AppModel) {
        let playOn = DetailCore.playOnDevices(app)
        let web = DetailCore.canOpenWeb
        model.setOptions(
            SwiftlyCore.DetailOptions(
                watchersShown: app.watchersShown, downloadButton: app.downloadButtonShow,
                maxBitrate: Int64(app.profileBitrate), canOpenWeb: web,
                onDevice: app.downloads.file(for: listItem.id) != nil, playOn: playOn,
                together: SharedModel.shared.mayCreate, continueWatching: false, inPlayer: false))
        model.setDownloaded(app.downloads.file(for: listItem.id) != nil)
    }

    /// Set once the load has been started, by `DetailWarm` ahead of the page or by `run`.
    @ObservationIgnored private var loadStarted = false

    /// Starts the load now (a film tile that rests under focus), so the rows are there when the page opens.
    func startLoad() {
        guard !loadStarted else { return }
        loadStarted = true
        model.load()
    }

    /// Loads (unless it already started), then keeps the parts current until the calling task is cancelled.
    func run(app: AppModel) async {
        send(options: app)
        startLoad()
        await model.observe()
    }

    /// Why the page could not be loaded at all (nothing but the list entry is on screen); `nil` otherwise.
    var trouble: Trouble? { model.hero.failure.map(Trouble.init) }

    // MARK: Intents the screens send

    func pressPlay(pick: String? = nil) -> PlayAction { model.play(pick: pick) }

    /// What a long press on Play lists: the versions with the default marked; empty when there is nothing to choose.
    func versions() -> [SwiftlyCore.VersionOption] { model.versions() }

    /// Settles after a refresh so a press on a title without known versions can decide again.
    func resolve(pick: String? = nil) async -> PlayAction {
        _ = await model.refreshSettled()
        return model.play(pick: pick)
    }
}

/// **Detail pages loaded ahead of the click** (Apple TV): a film tile that rests under focus starts its page's load, and the
/// page, when it opens, takes that core instead of making a cold one: header, chips and rows stand in the first frame.
/// The last few only, and none older than `maxAge` (the data would be stale).
@MainActor
enum DetailWarm {
    private static var cores: [(id: String, at: Date, core: DetailCore)] = []
    private static let maxAge: TimeInterval = 60

    static func prepare(_ item: Item, app: AppModel) {
        cores.removeAll { Date().timeIntervalSince($0.at) > maxAge }
        guard !cores.contains(where: { $0.id == item.id }), let core = DetailCore(app: app, item: item) else { return }
        core.startLoad()
        cores.append((item.id, Date(), core))
        if cores.count > 3 { cores.removeFirst() }
    }

    static func take(_ id: String) -> DetailCore? {
        guard let i = cores.firstIndex(where: { $0.id == id }) else { return nil }
        let hit = cores.remove(at: i)
        return Date().timeIntervalSince(hit.at) <= maxAge ? hit.core : nil
    }
}

/// Why a page could not be shown, for its own error copy: the server cannot be reached or answered with an
/// error (the shipping wording), refused the sign-in, or sent something unreadable.
enum Trouble: Equatable {
    case unreachable, server, denied, unreadable

    init(_ failure: SwiftlyCore.LoadFailure) {
        switch failure {
        case .offline: self = .unreachable
        case .failed(.server): self = .server
        case .failed(.denied): self = .denied
        case .failed(.unreadable): self = .unreadable
        }
    }

    /// From a screen's load state: a failure keeps its kind, anything else (offline, or unknown) is "unreachable".
    init(_ state: SwiftlyCore.LoadState) {
        if case .failed(let kind) = state {
            switch kind {
            case .server: self = .server
            case .denied: self = .denied
            case .unreadable: self = .unreadable
            }
        } else {
            self = .unreachable
        }
    }

    /// The heading and sentence of the whole-page error for this kind; `server` is the address or "Der Server".
    func copy(server: String) -> (title: LocalizedStringKey, text: LocalizedStringKey) {
        // Unreachable and server error keep the shipping wording; refused sign-in and unreadable answers get
        // their own, because "does it still run?" is the wrong question for them.
        switch self {
        case .unreachable, .server:
            ("Server ist abgetaucht", "\(server) antwortet nicht. Läuft er noch, oder hängt das WLAN?")
        case .denied:
            ("Anmeldung abgelehnt", "\(server) hat die Anmeldung abgelehnt. Wechsel den Server oder melde dich neu an.")
        case .unreadable:
            ("Antwort unlesbar", "\(server) hat etwas geschickt, das die App nicht lesen kann. Versuch es gleich nochmal.")
        }
    }
}

extension PlaybackPlan {
    /// The plan a view model already holds (the server's, or the copy on the device's), as the player takes it.
    @MainActor
    static func core(_ answer: SwiftlyCore.PlanOnly?, itemID: String, app: AppModel) -> PlaybackPlan? {
        guard let answer,
            case .ready(let url, let method, let mediaSourceId, let playSessionId, let sourceJson) = answer,
            let sourceJson,
            let source = try? JSONDecoder().decode(MediaSource.self, from: Data(sourceJson.utf8)),
            let address = URL(string: url)
        else { return nil }
        let delivery: DeliveryMethod =
            switch method {
            case .directPlay: .directPlay
            case .directStream: .directStream
            case .transcode: .transcode
            }
        return PlaybackPlan.assembled(
            url: address, method: delivery, mediaSourceID: mediaSourceId, playSessionID: playSessionId,
            source: source, itemID: itemID, profile: .vlc(maxBitrate: app.profileBitrate))
    }
}

extension SwiftlyCore.Tile {
    /// The tile a detail/series view model starts from, made of what the app knows of the title.
    init(standIn item: Item) {
        var badges: [SwiftlyCore.Badge] = []
        if item.userData?.played == true { badges.append(.watched) }
        if item.userData?.isFavorite == true { badges.append(.favorite) }
        if let count = item.userData?.unplayedItemCount, count > 0 { badges.append(.unplayed(count: UInt32(count))) }
        self.init(
            id: item.id, title: item.name, subtitle: nil,
            progress: item.userData?.playedPercentage.map { Float($0 / 100) }, image: nil, badges: badges,
            remaining: nil,
            facts: TileFacts(
                kind: item.type, name: item.name, year: item.productionYear.map(Int32.init),
                seriesId: item.seriesId, seasonId: item.seasonId,
                seasonNumber: item.parentIndexNumber.map(Int32.init),
                episodeNumber: item.indexNumber.map(Int32.init),
                childCount: item.childCount.map(Int32.init),
                // Where the user stopped, so the Play button is worded in the first frame ("Fortsetzen ab ...")
                // and not changed when the title arrives.
                positionTicks: item.userData?.playbackPositionTicks,
                runTimeTicks: item.runTimeTicks))
    }
}

// MARK: - Core parts as the existing components take them

extension PersonController {
    /// Details and filmography of the own server, then Seerr's (if connected); `titleVisible` loads more.
    func run(app: AppModel) async {
        try? await load()
        try? await loadSeerr(app.seerr.connected ? app.seerr.coreClient : nil)
    }
}

extension SwiftlyCore.PersonPage {
    var bannerURL: URL? { banner.flatMap { URL(string: $0) } }
    /// The Seerr titles as the Seerr tiles take them.
    var seerrHits: [JellyfinKit.SeerrHit] { requestableHits.map(SeerrCore.hit) }
}

extension Person {
    /// A cast head as the core names it. The cast tile carries only id, name and role.
    init(core cast: SwiftlyCore.CastTile) {
        self.init(id: cast.id, name: cast.name, role: cast.role, type: "Actor")
    }
}

extension Watcher {
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    /// A "Gesehen von" avatar as the core counted it.
    init(core tile: SwiftlyCore.WatcherTile) {
        let date = tile.lastWatched.flatMap { Self.iso.date(from: $0) }
        self.init(
            userID: tile.userId, name: tile.name, imageTag: nil, playCount: Int(tile.playCount), lastWatched: date,
            progressPercent: tile.ring < 1 && tile.ring > 0 ? tile.ring * 100 : nil,
            watchedCount: tile.watchedCount.map(Int.init), totalCount: tile.totalCount.map(Int.init))
    }
}

#if !os(iOS)
extension View {
    /// **Long press on Play (the remote's select held on TV, a right click on the Mac): the versions, nothing else.**
    ///
    /// No cover, no watched mark, no play entry: only the title's versions in the server's order, the default one
    /// checked; a pick runs `pick` and starts that one. The core decides what is offered (`versions`); without a choice
    /// (one version, a copy on the device, versions not known yet) the list is empty and the long press does nothing.
    /// A tap on the button itself always starts the default (the button's own action). The iPhone's `PlayMenu` is the
    /// same rule as a touch menu.
    func versionMenu(
        _ versions: [SwiftlyCore.VersionOption], pick: @escaping (SwiftlyCore.VersionOption) -> Void
    ) -> some View {
        contextMenu {
            ForEach(versions, id: \.id) { version in
                // A toggle shows the system check mark for the default; every row runs the pick.
                Toggle(isOn: Binding(get: { version.isDefault }, set: { _ in pick(version) })) {
                    Text(verbatim: version.label)
                }
            }
        }
    }
}
#endif

#if os(iOS)
/// **The Play button: a tap starts the default version, a long press lists the versions.**
///
/// Nothing stands in front of Play any more (no page, no sheet). With several versions the button is a menu
/// with a primary action: a tap runs `start`, a long press opens the system menu anchored to the button, with
/// the versions in the server's order and the default one checked; a pick runs `pick` and starts that one. The
/// core decides what is offered (`versions`); without a choice (one version, a copy on the device, versions not
/// known yet) it is a plain button and a long press does nothing.
struct PlayMenu<Label: View>: View {
    let versions: [SwiftlyCore.VersionOption]
    let start: () -> Void
    let pick: (SwiftlyCore.VersionOption) -> Void
    @ViewBuilder let label: () -> Label
    /// The current touch has been held long enough to count as a long press (only the plain button reads it).
    @State private var held = false

    var body: some View {
        if versions.isEmpty {
            // A button fires on release however long it was held. With nothing to list, a long hold must start
            // nothing either: a hold of half a second marks the touch, and the release of a marked touch is not a tap.
            Button {
                if held { held = false } else { start() }
            } label: {
                label()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onChanged { _ in held = false }
                    .onEnded { _ in held = true })
        } else {
            Menu {
                ForEach(versions, id: \.id) { version in
                    // A toggle shows the system check mark for the default; every row runs the pick.
                    Toggle(isOn: Binding(get: { version.isDefault }, set: { _ in pick(version) })) {
                        Text(verbatim: version.label)
                    }
                }
            } label: {
                label()
            } primaryAction: {
                start()
            }
            // No chevron next to the label: the button looks like the plain one.
            .menuIndicator(.hidden)
        }
    }
}
#endif
#endif
