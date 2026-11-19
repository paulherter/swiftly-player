import Foundation
import JellyfinKit
import Observation
import SwiftUI
import SwiftlyCore

/// The library page a Seerr tile stands for, when the own server has it.
enum SeerrOwn: Hashable {
    case title(Item)
    case person(Person)
    case collection(Item)
}

extension AppModel {
    /// Finds the library item of a Seerr tile by its TMDB id (`nil` when the server has none, or is not a
    /// Jellyfin/Emby one: Plex has no id lookup, so its tiles stay Seerr tiles).
    func ownTarget(for card: SeerrCard) async -> SeerrOwn? {
        guard let client = client as? JellyfinClient else { return nil }
        let kind: String
        switch card.art {
        case "person": kind = "Person"
        case "collection": kind = "BoxSet"
        case "tv": kind = "Series"
        default: kind = "Movie"
        }
        guard let id = try? await client.itemID(tmdb: Int(card.tmdb), kind: kind),
              let item = try? await client.item(id: id) else { return nil }
        switch card.art {
        case "person": return .person(Person(id: item.id, name: item.name, type: "Actor"))
        case "collection": return .collection(item)
        default: return .title(item)
        }
    }
}

/// **Search and discover over Seerr, as the Search page draws them.**
///
/// One object for the page: the empty page's rails and the merged search block. The core decides what is
/// shown (groups, words, the "nothing at Seerr" line, offline); this file keeps the records, resolves which
/// tile the own library has (so it opens its normal page) and never decides a word itself.
/// While Seerr is not connected nothing is loaded and `ready` stays false: the page draws no Seerr part.
@MainActor
@Observable
final class SeerrSearchFlow {
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var lists: SwiftlyCore.SeerrListsScreen
    @ObservationIgnored private var listsHub: SwiftlyCore.SeerrHub
    @ObservationIgnored private var current = ""

    /// Seerr is connected and its session works.
    private(set) var ready = false
    /// Connected, but the server does not answer at all (no session to read yet).
    private(set) var unreachable = false
    private(set) var rails: SwiftlyCore.SeerrDiscoverRails?
    private(set) var found: SwiftlyCore.SeerrSearchInfo?
    /// The library pages of tiles (by `SeerrCard.id`) that the own server has.
    private(set) var own: [String: SeerrOwn] = [:]

    init(model: AppModel) {
        self.model = model
        listsHub = model.seerr.hub
        lists = SwiftlyCore.SeerrListsScreen(hub: listsHub)
    }

    /// A different connection (account or Seerr switch) starts everything again.
    private func renew() {
        guard listsHub !== model.seerr.hub else { return }
        listsHub = model.seerr.hub
        lists = SwiftlyCore.SeerrListsScreen(hub: listsHub)
        ready = false
        unreachable = false
        rails = nil
        found = nil
        own = [:]
        current = ""
    }

    /// Asks the hub; false and nothing else without a connection.
    @discardableResult
    func prepare() async -> Bool {
        renew()
        guard model.seerr.connected else {
            ready = false
            unreachable = false
            return false
        }
        ready = await listsHub.ready()
        unreachable = !ready && listsHub.info().state == .offline
        return ready
    }

    // MARK: Discover

    func loadDiscover() async {
        // The rails of the last visit are there at once (the core's stash); the live read below replaces them.
        renew()
        if rails == nil, model.seerr.connected, let stale = try? await lists.restoreDiscover() {
            rails = stale
            ready = true
        }
        guard await prepare() else { return }
        let screen = lists
        guard let loaded = try? await screen.loadDiscover(), screen === lists else { return }
        rails = loaded
        // A title the library has only in part (some seasons) opens the library's page too: the season chooser
        // there requests the rest.
        await resolve(loaded.rails.flatMap(\.tiles).filter { $0.onServer || $0.badge?.kind == .partial })
    }

    // MARK: Search

    /// Searches `term` (empty resets). The caller has waited out the typing pause.
    func search(_ term: String) async {
        current = term
        guard !term.isEmpty else {
            found = nil
            return
        }
        guard await prepare() || unreachable else {
            found = nil
            return
        }
        guard ready else { return }
        let screen = lists
        guard let info = try? await screen.search(term: term), term == current, screen === lists else { return }
        found = info
        // Persons and collections open the library's own page; without one they have nowhere to go.
        await resolve(info.groups.filter { $0.kind == .people || $0.kind == .collections }.flatMap(\.tiles))
    }

    func reset() {
        current = ""
        found = nil
    }

    // MARK: What a Search page draws (one answer for every platform)

    /// Titles from Seerr that the own server does not have. The core already drops the ones Seerr says are
    /// available; a title the library search found by the same TMDB id (`known`) does not appear twice either.
    func tiles(known: Set<String>) -> [SeerrCard] {
        guard ready, let found, found.load == .content else { return [] }
        return found.groups
            .filter { $0.kind == .movies || $0.kind == .series }
            .flatMap(\.tiles)
            .filter { !known.contains(String($0.tmdb)) }
    }

    /// People of the Seerr search that the own library has (they open the person's page).
    var ownPeople: [(card: SeerrCard, person: Person)] {
        guard ready, let found else { return [] }
        return found.groups.filter { $0.kind == .people }.flatMap(\.tiles).compactMap { card in
            if case .person(let person)? = own[card.id] { return (card, person) }
            return nil
        }
    }

    /// Collections of the Seerr search that the own library has.
    var ownCollections: [Item] {
        guard ready, let found else { return [] }
        return found.groups.filter { $0.kind == .collections }.flatMap(\.tiles).compactMap { card in
            if case .collection(let item)? = own[card.id] { return item }
            return nil
        }
    }

    /// The page has something from Seerr to draw: tiles, a person or a collection the library has.
    func shows(known: Set<String>) -> Bool {
        !tiles(known: known).isEmpty || !ownPeople.isEmpty || !ownCollections.isEmpty
    }

    /// Seerr is connected but did not answer: one calm box, not an empty block.
    var offline: Bool { unreachable || (ready && found?.load == .offline) }

    func groupTitle(_ kind: SwiftlyCore.SearchGroupKind) -> String {
        found?.groups.first { $0.kind == kind }?.title ?? ""
    }

    /// The core's "Auch nicht bei Seerr." line, only when Seerr really answered with nothing.
    var nothingLine: String? {
        guard ready, found?.load == .empty else { return nil }
        return found?.nothingLine
    }

    /// The tiles the own library has, looked up side by side.
    private func resolve(_ cards: [SeerrCard]) async {
        let todo = cards.filter { own[$0.id] == nil }
        guard !todo.isEmpty else { return }
        let model = model
        let results = await withTaskGroup(of: (String, SeerrOwn?).self) { group in
            for card in todo.prefix(24) {
                group.addTask { (card.id, await model.ownTarget(for: card)) }
            }
            var done: [String: SeerrOwn] = [:]
            for await (id, target) in group { if let target { done[id] = target } }
            return done
        }
        guard !results.isEmpty else { return }
        withAnimation(Theme.reveal) { own.merge(results) { $1 } }
    }
}
