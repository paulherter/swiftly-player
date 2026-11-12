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

    /// Loads, then keeps the parts current until the calling task is cancelled.
    func run(app: AppModel) async {
        send(options: app)
        model.load()
        await model.observe()
    }

    /// Why the page could not be loaded at all (nothing but the list entry is on screen); `nil` otherwise.
    var trouble: Trouble? { model.hero.failure.map(Trouble.init) }

    // MARK: Intents the screens send

    func pressPlay(pick: String? = nil) -> PlayAction { model.play(pick: pick) }

    /// Settles after a refresh so a press on a title without known versions can decide again.
    func resolve(pick: String? = nil) async -> PlayAction {
        _ = await model.refreshSettled()
        return model.play(pick: pick)
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
                childCount: item.childCount.map(Int32.init)))
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

/// A title with several versions, waiting for the pick ("Fassung wählen"); the options are the core's.
struct VersionPick: Identifiable {
    let id = UUID()
    let heading: String
    let options: [SwiftlyCore.VersionOption]
    let since: Double
    /// The episode a series page asks about; `nil` on the movie page.
    var itemId: String? = nil
}

import SwiftUI

extension View {
    /// **"Fassung wählen"** with the core's version list: one button per version, the pick goes to `pick`.
    func versionPick(
        _ choice: Binding<VersionPick?>, pick: @escaping (VersionPick, SwiftlyCore.VersionOption) -> Void
    ) -> some View {
        confirmationDialog(
            choice.wrappedValue?.heading ?? "",
            isPresented: Binding(
                get: { choice.wrappedValue != nil }, set: { if !$0 { choice.wrappedValue = nil } }),
            titleVisibility: .visible, presenting: choice.wrappedValue
        ) { open in
            ForEach(open.options, id: \.id) { version in
                Button(version.label) { pick(open, version) }
            }
        }
    }
}
#endif
