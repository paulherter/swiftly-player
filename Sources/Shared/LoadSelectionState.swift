import Foundation
import JellyfinKit
import SwiftlyCore

/// **The download selection sheet's logic, from the core** (`LoadSelectionModel`): the checkbox
/// tree, the offered qualities, the audio options, the footer's space verdict and the season fetch
/// plan. The two sheets (`LoadSelection`, `MacLoadSelection`) keep their layout and read this.
///
/// The core knows ids and numbers; the episodes themselves (titles, sizes, what `proceed` needs)
/// stay here in `episodes`, and the wording of the counts stays in the host.
@MainActor @Observable
final class LoadSelectionState {
    private(set) var episodes: [String: [Item]] = [:]
    private(set) var seasons: [Item] = []
    private(set) var snap: LoadSheetState?
    private var core: LoadSelectionModel?
    private var free: Int64 = 0

    // MARK: Reading

    /// Every episode read so far, in season order.
    var allEpisodes: [Item] { seasons.compactMap { episodes[$0.id] }.flatMap { $0 } }
    var loads: Bool { snap?.loads ?? true }
    var disrupted: Bool { snap?.disrupted ?? false }
    var all: LoadCheck { snap?.all ?? .empty }
    var selectedCount: Int { snap?.selectedIds.count ?? 0 }
    var bytes: Int64 { snap?.bytes ?? 0 }
    var qualities: [DownloadQuality] { (snap?.qualities ?? ["original"]).compactMap(DownloadQuality.init(rawValue:)) }
    var audioOffered: Bool { snap?.audioOffered ?? false }
    var audioOptions: [DownloadAudioOption] {
        (snap?.audioOptions ?? []).map { DownloadAudioOption(choice: Self.choice($0.choice), label: $0.label) }
    }
    var audio: DownloadAudioChoice { snap.map { Self.choice($0.audio) } ?? .all }
    /// The selected episodes in season order (the core's ids are not ordered).
    var selectedEpisodes: [Item] {
        let ids = Set(snap?.selectedIds ?? [])
        return allEpisodes.filter { ids.contains($0.id) }
    }
    func row(_ season: String) -> LoadSeasonRow? { snap?.seasons.first { $0.seasonId == season } }
    func visibleItems(_ season: String) -> [Item] {
        let shown = Set(row(season)?.episodes.map(\.id) ?? [])
        return (episodes[season] ?? []).filter { shown.contains($0.id) }
    }

    var onlyUnwatched: Bool {
        get { snap?.onlyUnwatched ?? false }
        set { core?.setOnlyUnwatched(on: newValue); refresh() }
    }
    var quality: DownloadQuality {
        get { snap.flatMap { DownloadQuality(rawValue: $0.quality) } ?? .original }
        set { core?.setQuality(raw: newValue.rawValue); refresh() }
    }
    var audioChoice: DownloadAudioChoice {
        get { audio }
        set { core?.setAudio(choice: Self.coreChoice(newValue)); refresh() }
    }

    // MARK: Taps

    func toggleAll() { core?.toggleAll(); refresh() }
    func toggleSeason(_ id: String) { core?.toggleSeason(seasonId: id); refresh() }
    func toggleEpisode(_ id: String) { core?.toggleEpisode(episodeId: id); refresh() }

    /// Free space changed (the footer's verdict follows it).
    func spaceChanged(_ bytes: Int64) { free = bytes; refresh() }

    /// What the downloads hold changed: those episodes can no longer be selected.
    func setPresent(_ ids: [String]) { core?.setPresent(ids: ids); refresh() }

    // MARK: Loading

    /// **Each season once, and the cache counts.** The core plans the batches (three at a time);
    /// `fetch` asks the server for one season (`nil` = failed, `[]` = empty).
    func load(seasons: [Item], preloaded: [String: [Item]], audioLanguage: String, selectQuality: Bool,
              free: Int64, isPresent: (String) -> Bool, learned: (String, [Item]) -> Void,
              fetch: @escaping @Sendable (String) async -> [Item]?) async {
        self.seasons = seasons
        self.free = free
        episodes = preloaded
        guard let made = try? LoadSelectionModel(
            seasonIds: seasons.map(\.id),
            preloaded: preloaded.compactMap { id, list in Self.json(list).map { LoadSeasonEpisodes(seasonId: id, episodesJson: $0) } },
            locale: AppCore.language, audioLanguage: audioLanguage, selectQuality: selectQuality)
        else { return }
        core = made
        made.setPresent(ids: allEpisodes.map(\.id).filter(isPresent))
        let batches = made.beginLoad()
        refresh()
        for batch in batches {
            let answers = await withTaskGroup(of: (String, [Item]?).self) { group in
                for id in batch { group.addTask { (id, await fetch(id)) } }
                var out: [(String, [Item]?)] = []
                for await answer in group { out.append(answer) }
                return out
            }
            for (id, list) in answers {
                if let list { episodes[id] = list; learned(id, list) }
                try? made.recordSeason(seasonId: id, episodesJson: list.flatMap(Self.json))
            }
            refresh()
        }
        made.finishLoad()
        // What was downloaded since the last open is no longer selectable.
        made.setPresent(ids: allEpisodes.map(\.id).filter(isPresent))
        refresh()
    }

    private func refresh() { snap = core?.state(free: free) }

    // MARK: Wording

    func episodesNumber(_ n: Int) -> String {
        n == 1 ? String(localized: "1 Folge") : String(localized: "\(n) Folgen")
    }

    func numberAndSize(_ count: Int, _ bytes: Int64) -> String {
        episodesNumber(count) + " · " + DownloadRules.size(bytes)
    }

    /// **"Whole series" names only what is still missing.**
    var seriesRight: String {
        if loads { return String(localized: "wird gelesen …") }
        if all == .present { return String(localized: "alles da") }
        let rows = snap?.seasons.flatMap(\.episodes) ?? []
        if !allEpisodes.isEmpty, rows.isEmpty { return String(localized: "alles gesehen") }
        let take = Set(rows.filter { !$0.present }.map(\.id))
        let size = allEpisodes.filter { take.contains($0.id) }.reduce(Int64(0)) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
        return numberAndSize(take.count, size)
    }

    func seasonRight(_ season: String) -> String {
        switch row(season)?.right {
        case .reading: String(localized: "wird gelesen …")
        case .dash, nil: "—"
        case .noEpisodes: String(localized: "Keine Folgen")
        case .allWatched: String(localized: "alles gesehen")
        case .allThere: String(localized: "alles da")
        case .count(let n): episodesNumber(Int(n))
        }
    }

    // MARK: Conversions

    private static func choice(_ c: LoadAudio) -> DownloadAudioChoice {
        switch c {
        case .all: .all
        case .track(let i): .track(Int(i))
        case .language(let k): .language(k)
        }
    }

    private static func coreChoice(_ c: DownloadAudioChoice) -> LoadAudio {
        switch c {
        case .all: .all
        case .track(let i): .track(index: Int64(i))
        case .language(let k): .language(key: k)
        }
    }

    /// The server's `Items` array: `Item` encodes under the server's own keys.
    nonisolated static func json(_ list: [Item]) -> String? {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
