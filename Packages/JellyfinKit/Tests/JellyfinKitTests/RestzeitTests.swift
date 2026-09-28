import Foundation
import Testing
@testable import JellyfinKit

@Suite struct RestzeitTests {
    @Test func minutenWerdenAufgerundet() {
        #expect(Restzeit.teile(sekunden: 40) == (0, 1))
        #expect(Restzeit.teile(sekunden: 12 * 60) == (0, 12))
        #expect(Restzeit.teile(sekunden: 12 * 60 + 1) == (0, 13))
    }

    @Test func stundenUndMinuten() {
        #expect(Restzeit.teile(sekunden: 64 * 60) == (1, 4))
        #expect(Restzeit.teile(sekunden: 120 * 60) == (2, 0))
    }

    @Test func unsinnigeWerte() {
        #expect(Restzeit.teile(sekunden: .nan) == (0, 1))
        #expect(Restzeit.teile(sekunden: -5) == (0, 1))
    }

    @Test func zeileNurMitStand() {
        let film = Item(id: "f", name: "Film", type: "Movie", runTimeTicks: 3600 * 10_000_000)
        #expect(film.weiterschauenzeile == nil)
    }

    @Test("Film unter Weiterschauen nennt das Jahr vor der Restzeit")
    func filmNenntJahr() {
        let film = Item(id: "f", name: "Film", type: "Movie", productionYear: 2019,
                        runTimeTicks: 7200 * 10_000_000,
                        userData: UserItemData(playbackPositionTicks: 3600 * 10_000_000))
        #expect(film.kontextzeile == "2019")
        let zeile = try! #require(film.weiterschauenzeile)
        #expect(zeile.hasPrefix("2019 · "))
    }

    @Test("Film ohne Jahr: nur die Restzeit, keine leere Angabe davor")
    func filmOhneJahr() {
        let film = Item(id: "f", name: "Film", type: "Movie",
                        runTimeTicks: 7200 * 10_000_000,
                        userData: UserItemData(playbackPositionTicks: 3600 * 10_000_000))
        #expect(film.kontextzeile == nil)
        let zeile = try! #require(film.weiterschauenzeile)
        #expect(!zeile.contains("·"))
    }
}
