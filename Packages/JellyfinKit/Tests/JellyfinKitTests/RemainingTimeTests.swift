import Foundation
import Testing
@testable import JellyfinKit

@Suite struct RemainingTimeTests {
    @Test func minutesWhoRoundedUp() {
        #expect(RemainingTime.parts(seconds: 40) == (0, 1))
        #expect(RemainingTime.parts(seconds: 12 * 60) == (0, 12))
        #expect(RemainingTime.parts(seconds: 12 * 60 + 1) == (0, 13))
    }

    @Test func hoursAndMinutes() {
        #expect(RemainingTime.parts(seconds: 64 * 60) == (1, 4))
        #expect(RemainingTime.parts(seconds: 120 * 60) == (2, 0))
    }

    @Test func nonsenseValues() {
        #expect(RemainingTime.parts(seconds: .nan) == (0, 1))
        #expect(RemainingTime.parts(seconds: -5) == (0, 1))
    }

    @Test func rowOnlyWithState() {
        let film = Item(id: "f", name: "Film", type: "Movie", runTimeTicks: 3600 * 10_000_000)
        #expect(film.continueWatchingRow == nil)
    }

    @Test("Film unter Weiterschauen nennt das Jahr vor der Restzeit")
    func filmNamesYear() {
        let film = Item(id: "f", name: "Film", type: "Movie", productionYear: 2019,
                        runTimeTicks: 7200 * 10_000_000,
                        userData: UserItemData(playbackPositionTicks: 3600 * 10_000_000))
        #expect(film.contextLine == "2019")
        let row = try! #require(film.continueWatchingRow)
        #expect(row.hasPrefix("2019 · "))
    }

    @Test("Film ohne Jahr: nur die Restzeit, keine leere Angabe davor")
    func filmWithoutYear() {
        let film = Item(id: "f", name: "Film", type: "Movie",
                        runTimeTicks: 7200 * 10_000_000,
                        userData: UserItemData(playbackPositionTicks: 3600 * 10_000_000))
        #expect(film.contextLine == nil)
        let row = try! #require(film.continueWatchingRow)
        #expect(!row.contains("·"))
    }
}
