import Foundation
import JellyfinKit
import Testing

@testable import SwiftlyCore

/// What the Mac (and the tvOS) tiles used to say from an `Item` against what the core's tiles say, on the
/// same fixture catalog: title line and second line per rail. The Mac views now read the core's tiles, so
/// every difference here would be a visible change.
@Suite(.serialized) struct TileTextParityTests {
    private func catalog() throws -> [String: Item] {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appending(path: "crates/swiftly-vm/tests/fixtures/catalog.json"))
        struct Wrapper: Decodable { let Items: [Item] }
        let items = try JSONDecoder().decode(Wrapper.self, from: data).Items
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    /// The old "Continue Watching" second line (`Item.continueWatchingRow`, Sources/Shared/TitleDetails.swift),
    /// written out the same way for German.
    private func oldContinueLine(_ item: Item) -> String? {
        guard let total = item.runtimeSeconds, total > 0, let since = item.resumeFrom else { return nil }
        let (hours, minutes) = RemainingTime.parts(seconds: total - since)
        let rest =
            hours == 0 ? "noch \(minutes) Min." : minutes == 0 ? "noch \(hours) Std." : "noch \(hours) Std. \(minutes) Min."
        guard item.type == "Episode", let season = item.parentIndexNumber, let episode = item.indexNumber else {
            if item.type == "Movie", let year = item.contextLine { return year + " · " + rest }
            return rest
        }
        return "S\(season) · F\(episode) · " + rest
    }

    private func germanCode(_ item: Item) -> String? {
        guard let season = item.parentIndexNumber, let episode = item.indexNumber else { return nil }
        return "S\(season) · F\(episode)"
    }

    @Test @MainActor func homeTilesSayWhatTheOldTilesSaid() async throws {
        let items = try catalog()
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let model = HomeModel(vm: try makeCore().homeVm(account: account(server), locale: "de"))
        let observing = Task { @MainActor in await model.observe() }
        model.load()
        #expect(await eventuallyOnMain { model.status.status == .ready && !model.status.preview })

        var seen = 0
        for rail in model.rails.rails {
            for tile in rail.tiles {
                let item = try #require(items[tile.id])
                seen += 1
                // The title line: the series name where there is one, as `HomeView.header`.
                #expect(tile.title == (item.seriesName ?? item.name), "\(rail.id) \(tile.id) title")
                let old: String?
                switch rail.id {
                case "weiterschauen": old = oldContinueLine(item) ?? item.contextLine
                // German letters (`episodeCode` follows the machine's language, the core was asked for "de").
                case "naechsteFolge": old = germanCode(item)
                default: old = item.newArrivalsRow
                }
                // What the Swift side shows: the whole line of "Continue watching" is `remaining`
                // (`RustTileLook`), everything else `subtitle`.
                #expect(tile.remaining ?? tile.subtitle == old, "\(rail.id) \(tile.id) second line")
            }
        }
        #expect(seen >= 3)
        observing.cancel()
        await observing.value
    }

    @Test @MainActor func libraryAndSearchTilesSayWhatTheOldTilesSaid() async throws {
        let items = try catalog()
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let search = SearchModel(vm: try makeCore().searchVm(account: account(server), locale: "de"))
        let observing = Task { @MainActor in await search.observe() }
        search.query("nord")
        #expect(await eventuallyOnMain { search.status.status == .done })
        observing.cancel()
        var seen = 0
        for tile in search.results.groups.flatMap(\.tiles) {
            let item = try #require(items[tile.id])
            seen += 1
            #expect(tile.title == item.name, "search \(tile.id) title")
            // The grouped line under a search hit: year (and the seasons of a series).
            let year = item.productionYear.map(String.init)
            #expect(tile.subtitle == year, "search \(tile.id) second line")
        }
        #expect(seen >= 1)
    }
}
