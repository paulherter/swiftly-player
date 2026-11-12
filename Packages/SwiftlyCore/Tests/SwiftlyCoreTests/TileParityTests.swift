import Foundation
import JellyfinKit
import Testing

@testable import SwiftlyCore

/// What the Apple TV's tiles showed before they read the core: the Swift `Item` expressions
/// (`seriesName ?? name`, `continueWatchingRow`, `episodeCode`, `newArrivalsRow`, `watchedShare`,
/// `tileMark` inputs) on the recorded server titles, against the tiles of the core's home page.
@Suite(.serialized) struct TileParityTests {
    private func recorded() throws -> [String: Item] {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appending(path: "crates/swiftly-vm/tests/fixtures/catalog.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(object["Items"] as? [[String: Any]])
        var items: [String: Item] = [:]
        for raw in list {
            let item = try JSONDecoder().decode(
                Item.self, from: try JSONSerialization.data(withJSONObject: raw))
            items[item.id] = item
        }
        return items
    }

    @Test @MainActor func theCoreTilesReadLikeTheOldTVTiles() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let old = try recorded()
        let model = HomeModel(vm: try makeCore().homeVm(account: account(server), locale: "en"))
        await model.loadSettled()
        var compared = 0
        for rail in model.rails.rails {
            for tile in rail.tiles {
                let item = try #require(old[tile.id])
                #expect(tile.title == (item.seriesName ?? item.name), "title of \(tile.id)")
                switch rail.kind {
                case .continueWatching:
                    #expect(tile.remaining == item.continueWatchingRow, "remaining of \(tile.id)")
                case .nextEpisode:
                    #expect(tile.subtitle == item.episodeCode, "line of \(tile.id)")
                case .newArrivals:
                    #expect(tile.subtitle == item.newArrivalsRow, "new line of \(tile.id)")
                default: break
                }
                if let share = item.watchedShare, let progress = tile.progress {
                    #expect(abs(Double(progress) - share) < 0.001, "progress of \(tile.id)")
                }
                // The marks of a tile (`tileMark`): the stand-in `Item` carries what it needs.
                var watched = false
                var unplayed: Int?
                for badge in tile.badges {
                    if case .watched = badge { watched = true }
                    if case .unplayed(let count) = badge { unplayed = Int(count) }
                }
                #expect(
                    DisplayRules.tileMark(
                        art: tile.facts.kind, seasons: tile.facts.childCount.map(Int.init),
                        watched: watched ? true : nil, openEpisodes: unplayed)
                        == DisplayRules.tileMark(
                            art: item.type, seasons: item.childCount, watched: item.userData?.played,
                            openEpisodes: item.userData?.unplayedItemCount),
                    "mark of \(tile.id)")
                compared += 1
            }
        }
        #expect(compared >= 5)
    }
}
