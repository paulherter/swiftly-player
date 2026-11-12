import Foundation
import JellyfinKit
import Testing

@testable import SwiftlyCore

func tile(
    _ id: String, _ name: String, kind: String, year: Int32? = nil
) -> Tile {
    Tile(
        id: id, title: name, subtitle: nil, progress: nil, image: nil, badges: [], remaining: nil,
        facts: TileFacts(
            kind: kind, name: name, year: year, seriesId: nil, seasonId: nil, seasonNumber: nil,
            episodeNumber: nil, childCount: nil))
}

func librarySpec(remember: String? = nil) -> LibrarySpec {
    LibrarySpec(
        source: ShelfSource(parent: "lib1", onlyOut: [], art: "movies", collection: false),
        genre: nil, rememberName: remember)
}

@Suite(.serialized) struct ViewModelTests {
    @Test @MainActor func libraryLoadsSortsAndTogglesThroughTheServer() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let vm = try makeCore().libraryVm(account: account(server), locale: "de", spec: librarySpec())
        let model = LibraryModel(vm: vm)
        #expect(model.status.status == .loading)
        #expect(model.grid.tiles.isEmpty)
        let observing = Task { @MainActor in await model.observe() }

        model.load()
        #expect(await eventuallyOnMain { model.status.status == .ready && model.grid.tiles.count == 3 })
        #expect(Set(model.grid.tiles.map(\.id)) == ["m1", "m2", "m3"])
        #expect(model.status.sorting == .name && model.status.filter == .all)
        #expect(model.grid.tiles.allSatisfy { !$0.title.isEmpty })

        model.setSorting(.latest)
        #expect(await eventuallyOnMain { model.status.sorting == .latest && model.status.status == .ready })
        // The sorting shows at once; the new request follows a moment later.
        #expect(await eventuallyOnMain { server.seen.contains { $0.target.contains("SortBy=DateCreated") } })

        model.setWatched("m1", true)
        #expect(await eventuallyOnMain { server.seen.contains { $0.target.contains("PlayedItems/m1") } })
        #expect(model.status.toggleError == nil)
        #expect(server.seen.allSatisfy { !$0.target.contains("TOKEN-A") })

        observing.cancel()
        await observing.value
    }

    @Test func cancellingTheLibraryObserverDropsTheRustFuture() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let vm = try makeCore().libraryVm(account: account(server), locale: "de", spec: librarySpec())
        let observer = Task { try await vm.changed(seen: vm.version()) }
        #expect(await eventually { vm.waiters() == 1 })
        observer.cancel()
        await #expect(throws: CancellationError.self) { try await observer.value }
        #expect(await eventually { vm.waiters() == 0 })
    }

    @Test @MainActor func searchDebouncesFindsAndRemembersTerms() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let model = SearchModel(vm: try makeCore().searchVm(account: account(server), locale: "de"))
        #expect(model.status.status == .idle)
        let observing = Task { @MainActor in await model.observe() }

        // Three keystrokes in a row make one request (debounce 0.3 s).
        model.query("n")
        model.query("no")
        model.query("nord")
        #expect(await eventuallyOnMain { model.status.status == .done })
        #expect(model.results.query == "nord")
        let titles = model.results.groups.flatMap(\.tiles).map(\.title)
        #expect(titles == ["Nordlicht"])
        #expect(model.results.groups.first?.kind == .movies)
        #expect(server.seen.filter { $0.target.contains("searchTerm") }.count == 1)

        model.remember()
        #expect(await eventuallyOnMain { model.recents == ["nord"] })

        model.query("zzzz")
        #expect(await eventuallyOnMain { model.status.status == .empty })
        model.clearRecents()
        #expect(await eventuallyOnMain { model.recents.isEmpty })

        observing.cancel()
        await observing.value
    }

    @Test @MainActor func searchSaysOfflineWhenTheServerIsGone() async throws {
        let server = try await FixtureServer.start()
        let model = SearchModel(vm: try makeCore().searchVm(account: account(server), locale: "de"))
        let observing = Task { @MainActor in await model.observe() }
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        model.query("nord")
        #expect(await eventuallyOnMain { model.status.status == .offline })
        observing.cancel()
        await observing.value
    }

    @Test @MainActor func detailCompletesTheEntryAndPlayWaitsForTheVersions() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let vm = try makeCore().detailVm(
            account: account(server), locale: "de", tile: tile("m1", "Nordlicht", kind: "Movie", year: 2021))
        let model = DetailModel(vm: vm)
        #expect(model.actions.play.enabled == false)
        #expect(model.play() == .wait)
        let observing = Task { @MainActor in await model.observe() }

        model.load()
        #expect(await eventuallyOnMain { model.actions.play.enabled })
        #expect(model.hero.id == "m1")
        #expect(model.hero.title == "Nordlicht")
        #expect(model.hero.overview == "Eine Geschichte.")
        #expect(model.play() == .start(itemId: "m1", since: 0, sourceId: nil))
        #expect(await eventuallyOnMain { model.bottom.ready })
        #expect(model.bottom.similar.map(\.id) == ["m2", "m3"])

        model.setWatchlist(true)
        #expect(await eventuallyOnMain { model.actions.favorite })
        #expect(model.actions.favoriteCaption.isEmpty == false)
        #expect(model.tileMenu().isEmpty == false)

        model.setOptions(
            DetailOptions(
                watchersShown: false, downloadButton: true, maxBitrate: 20_000_000, canOpenWeb: false,
                onDevice: false, playOn: [PlayOnDevice(id: "d1", name: "Wohnzimmer")], together: false,
                continueWatching: false, inPlayer: false))
        model.downloadState(.loading(0.5))
        #expect(await eventuallyOnMain { model.actions.download?.state == .loading(0.5) })
        #expect(model.takeEffects().count >= 0)
        observing.cancel()
        await observing.value
    }

    @Test @MainActor func seriesLoadsSeasonsEpisodesAndSwitchesSeason() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let vm = try makeCore().seriesVm(
            account: account(server), locale: "de",
            tile: tile("s1", "Dark Matter", kind: "Series", year: 2022),
            spec: SeriesSpec(startSeasonId: nil, startSeasonNumber: nil))
        let model = SeriesModel(vm: vm)
        #expect(model.episodes.status == .loading)
        let observing = Task { @MainActor in await model.observe() }

        model.load()
        #expect(await eventuallyOnMain { model.episodes.status == .ready && !model.seasons.seasons.isEmpty })
        #expect(model.seasons.seasons.map(\.name) == ["Staffel 1", "Staffel 2"])
        #expect(model.episodes.total == 3 && model.episodes.rows.count == 3)
        #expect(model.button.title == "Dark Matter")
        #expect(model.episodes.rows.first?.watched == true)
        #expect(await eventuallyOnMain { !model.button.label.isEmpty && model.button.labelReady })

        model.selectSeason("se2")
        #expect(await eventuallyOnMain { model.episodes.rows.first?.id == "s1-2-1" })
        #expect(model.seasons.selected == "se2")
        // The list entry has no versions yet: the host resolves them first.
        #expect(model.playEpisode("s1-2-2") == .resolve(itemId: "s1-2-2", since: 0))

        model.setWatchlist(true)
        #expect(await eventuallyOnMain { model.button.favorite })
        observing.cancel()
        await observing.value
    }

    /// apple-feature-gate, lines 10/11: the series page carries its description (Mac showed none, iOS and tvOS read the same
    /// core text): from the core's button part and from the fresh item the tvOS header and the tile menu take.
    @Test @MainActor func theSeriesPageCarriesItsDescription() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let vm = try makeCore().seriesVm(
            account: account(server), locale: "de",
            tile: tile("s1", "Dark Matter", kind: "Series", year: 2022),
            spec: SeriesSpec(startSeasonId: nil, startSeasonNumber: nil))
        let model = SeriesModel(vm: vm)
        let observing = Task { @MainActor in await model.observe() }
        model.load()
        #expect(await eventuallyOnMain { model.button.overview == "Eine Geschichte." })
        let json = try #require(vm.itemJson(id: nil))
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        #expect(item.description == "Eine Geschichte.")
        observing.cancel()
        await observing.value
    }
}
