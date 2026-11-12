import Foundation
import Testing

@testable import SwiftlyCore

/// The person page and the playlist page over the scripted server (the old Swift loading is gone;
/// these pin what the core hands the views: sections, rows, empty and failed states).
@Suite(.serialized) struct PersonPlaylistTests {
    private let anna = PersonInfo(id: "p1", name: "Anna Muster", role: "Hauptrolle", kind: "Actor", imageTag: nil)

    @MainActor private func person(_ server: FixtureServer) throws -> PersonController {
        PersonController(model: try makeCore().personModel(account: account(server), locale: "de", person: anna, origin: nil))
    }

    @MainActor private func playlist(_ server: FixtureServer, art: String? = nil) throws -> PlaylistController {
        let list = tile("pl1", "Abend", kind: "Playlist")
        return PlaylistController(model: try makeCore().playlistModel(account: account(server), locale: "de", playlist: list, art: art))
    }

    @Test @MainActor func aPersonPageFillsItsFilmographyInOrderAndKeepsTheRoleLine() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let c = try person(server)
        #expect(!c.page.loaded && c.page.titles.isEmpty)
        try await c.load()
        #expect(c.page.loaded && !c.page.disrupted)
        #expect(c.page.name == "Anna Muster")
        #expect(c.page.titles.map(\.id) == ["m1", "m2", "m3"])
        #expect(c.page.total == 3)
        #expect(c.page.emptyText == nil)
        #expect(c.page.requestableHits.isEmpty && c.page.requestable.isEmpty)
    }

    @Test @MainActor func withoutSeerrAPersonWithTitlesSaysNothingMore() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let c = try person(server)
        try await c.load()
        try await c.loadSeerr(nil)
        #expect(c.page.requestable.isEmpty && c.page.requestableHits.isEmpty)
        #expect(c.page.emptyText == nil)
    }

    @Test @MainActor func aPersonWithoutTitlesShowsTheEmptyTextOnlyAfterSeerrAnswered() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.answerEmptyLists()
        let c = try person(server)
        try await c.load()
        #expect(c.page.loaded && !c.page.disrupted && c.page.titles.isEmpty)
        #expect(c.page.emptyText == nil)
        try await c.loadSeerr(nil)
        #expect(c.page.emptyText?.contains("Anna Muster") == true)
        #expect(c.page.banner == nil)
    }

    @Test @MainActor func aSilentServerIsDisruptedNotEmpty() async throws {
        let server = try await FixtureServer.start()
        let c = try person(server)
        server.stop()
        try await c.load()
        #expect(c.page.disrupted)
        #expect(c.page.titles.isEmpty && c.page.emptyText == nil)
    }

    @Test @MainActor func aPlaylistKeepsItsRowsInOrderAndPlaysTheFirst() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let c = try playlist(server)
        #expect(c.page.loading && c.page.empty == nil)
        try await c.load()
        #expect(c.page.title == "Abend")
        #expect(c.page.shown.map(\.id) == ["m1", "m2", "m3"])
        #expect(c.page.count == 3)
        #expect(!c.page.loading && !c.page.disrupted && c.page.empty == nil)
        #expect(c.start()?.id == "m1")
    }

    @Test @MainActor func anEmptyPlaylistOffersTheReload() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.answerEmptyLists()
        let c = try playlist(server)
        try await c.load()
        let empty = try #require(c.page.empty)
        #expect(empty.headline == "Hier ist noch nichts")
        #expect(empty.button == "Aktualisieren")
        #expect(c.page.count == nil && c.start() == nil)
    }

    @Test @MainActor func aSilentServerFailsAPlaylistOnlyWhileNothingWasLoaded() async throws {
        let server = try await FixtureServer.start()
        let c = try playlist(server)
        try await c.load()
        #expect(c.page.shown.count == 3)
        server.stop()
        try await c.load()
        #expect(!c.page.disrupted, "what was loaded stays")
        #expect(c.page.shown.count == 3)
        let fresh = try playlist(server)
        try await fresh.load()
        #expect(fresh.page.disrupted && fresh.page.empty == nil)
    }
}
