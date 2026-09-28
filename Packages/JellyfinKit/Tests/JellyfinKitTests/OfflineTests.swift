import Foundation
import Testing
@testable import JellyfinKit

/// Downloads ohne Netz (1.0.5): Abschnitte, naechste Folge, Sehstand und
/// die Nachmeldung beim Wiederverbinden.
@Suite("Offline")
struct OfflineTests {

    private func folge(_ id: String, staffel: Int?, _ nummer: Int?,
                       serie: String? = "s1", konto: String = "u1",
                       stand: Downloadstand = .fertig,
                       laufzeit: Int64 = 1_000) -> Downloadposten {
        Downloadposten(id: id, konto: konto, art: .folge, titel: id,
                       serie: "Serie", serienId: serie, staffel: staffel, folge: nummer,
                       laufzeitTicks: laufzeit, container: "mkv", bytes: 1, stand: stand)
    }

    // MARK: Naechste Folge

    @Test("Die naechste geladene Folge derselben Staffel")
    func naechsteInStaffel() {
        let liste = [folge("e3", staffel: 1, 3), folge("e1", staffel: 1, 1), folge("e2", staffel: 1, 2)]
        #expect(Downloadregeln.folgeNach("e1", aus: liste)?.id == "e2")
        #expect(Downloadregeln.folgeNach("e2", aus: liste)?.id == "e3")
        #expect(Downloadregeln.folgeNach("e3", aus: liste) == nil)
    }

    @Test("Ueber das Staffelende hinweg, und eine Luecke wird uebersprungen")
    func staffelwechselUndLuecke() {
        let liste = [folge("a", staffel: 1, 9), folge("b", staffel: 2, 1), folge("c", staffel: 2, 4)]
        #expect(Downloadregeln.folgeNach("a", aus: liste)?.id == "b")
        #expect(Downloadregeln.folgeNach("b", aus: liste)?.id == "c")
    }

    @Test("Specials kommen nach einer regulaeren Folge nicht dran")
    func specials() {
        let liste = [folge("a", staffel: 1, 1), folge("sp", staffel: 0, 1), folge("b", staffel: 1, 2)]
        #expect(Downloadregeln.folgeNach("a", aus: liste)?.id == "b")
        #expect(Downloadregeln.folgeNach("b", aus: liste) == nil)
    }

    @Test("Nur fertige Downloads, nur dieselbe Serie, nur dasselbe Konto")
    func nurPassende() {
        let liste = [folge("a", staffel: 1, 1),
                     folge("b", staffel: 1, 2, stand: .laedt),
                     folge("c", staffel: 1, 3, serie: "andere"),
                     folge("d", staffel: 1, 4, konto: "u2"),
                     folge("e", staffel: 1, 5)]
        #expect(Downloadregeln.folgeNach("a", aus: liste)?.id == "e")
    }

    @Test("Ohne Nummer, ohne Serie oder bei einem Film gibt es keine")
    func nichtsZuOrdnen() {
        let film = Downloadposten(id: "f", konto: "u1", art: .film, titel: "f", bytes: 1, stand: .fertig)
        let liste = [folge("a", staffel: 1, nil), folge("b", staffel: 1, 2), film,
                     folge("x", staffel: 1, 1, serie: nil)]
        #expect(Downloadregeln.folgeNach("a", aus: liste) == nil)
        #expect(Downloadregeln.folgeNach("f", aus: liste) == nil)
        #expect(Downloadregeln.folgeNach("x", aus: liste) == nil)
        #expect(Downloadregeln.folgeNach("fehlt", aus: liste) == nil)
    }

    // MARK: Abschnitte

    @Test("Abschnitte ueberstehen die Ablage — in Ticks, wie vom Server")
    func abschnitteAblage() throws {
        var p = folge("a", staffel: 1, 1)
        p.abschnitte = [Abschnitt(art: .vorspann, von: 12.5, bis: 71.25),
                        Abschnitt(art: .abspann, von: 2_500, bis: 2_580)]
        let roh = try JSONEncoder().encode([p])
        let zurueck = try JSONDecoder().decode([Downloadposten].self, from: roh)
        #expect(zurueck[0].abschnitte == p.abschnitte)
        #expect(String(decoding: roh, as: UTF8.self).contains("\"StartTicks\":125000000"))
    }

    @Test("Eine Liste von vor 1.0.5 liest sich weiter")
    func alteListe() throws {
        let roh = """
        [{"id":"a","konto":"u1","art":"folge","titel":"A","bytes":1,"geladen":1,
          "stand":"fertig","gesehen":true,"angelegt":1000,"nochAufDemServer":true}]
        """
        let p = try JSONDecoder().decode([Downloadposten].self, from: Data(roh.utf8))
        #expect(p[0].abschnitte == nil)
        #expect(p[0].stelleTicks == nil)
        #expect(p[0].zuletzt == nil)
        #expect(p[0].gesehen)
    }

    @Test("Abgelegte Abschnitte gelten ohne Anfrage, sonst fragt der Server")
    func abschnitteWahl() async {
        let server = [Abschnitt(art: .vorspann, von: 1, bis: 40)]
        let abgelegt = [Abschnitt(art: .vorspann, von: 2, bis: 30)]
        let a = await Downloadregeln.abschnitte(abgelegt: abgelegt) {
            Issue.record("mit Abgelegtem wird nicht gefragt"); return server
        }
        #expect(a == abgelegt)
        #expect(await Downloadregeln.abschnitte(abgelegt: []) { server } == server)
        #expect(await Downloadregeln.abschnitte(abgelegt: nil) { [] }.isEmpty)
    }

    private struct Weg: Error {}

    @Test("Naechste Folge: ohne Netz die geladene, ohne Frage an den Server")
    func naechsteOhneNetz() async {
        let liste = [folge("e1", staffel: 1, 1), folge("e2", staffel: 1, 2)]
        let jetzt = liste[0].alsItem
        let n = await Downloadregeln.folgeNach(jetzt, aus: liste, ohneNetz: true) {
            Issue.record("ohne Netz wird nicht gefragt"); return nil
        }
        #expect(n?.id == "e2")
    }

    @Test("Naechste Folge: mit Netz wie bisher, bei Fehler die geladene")
    func naechsteMitNetz() async {
        let liste = [folge("e1", staffel: 1, 1), folge("e2", staffel: 1, 2)]
        let jetzt = liste[0].alsItem
        let vomServer = Item(id: "e2-server", name: "E2")
        #expect(await Downloadregeln.folgeNach(jetzt, aus: liste, ohneNetz: false) { vomServer }?.id == "e2-server")
        // Der Server sagt „keine" — dabei bleibt es.
        #expect(await Downloadregeln.folgeNach(jetzt, aus: liste, ohneNetz: false) { nil } == nil)
        #expect(await Downloadregeln.folgeNach(jetzt, aus: liste, ohneNetz: false) { throw Weg() }?.id == "e2")
        // Nicht geladen: bei Fehler keine.
        let fremd = Item(id: "x", name: "X", type: "Episode", seriesId: "s1")
        #expect(await Downloadregeln.folgeNach(fremd, aus: liste, ohneNetz: false) { throw Weg() } == nil)
    }

    // MARK: Sehstand auf dem Geraet

    @Test("Ueber 90 Prozent ist gesehen, die Stelle faellt weg")
    func gesehenAmEnde() {
        let p = folge("a", staffel: 1, 1).nachWiedergabe(ticks: 950, wann: Date(timeIntervalSince1970: 5))
        #expect(p.gesehen)
        #expect(p.stelleTicks == nil)
        #expect(p.fortsetzenAb == 0)
        #expect(p.zuletzt == Date(timeIntervalSince1970: 5))
    }

    @Test("Dazwischen wird die Stelle gemerkt, gesehen bleibt, wie es war")
    func stelleDazwischen() {
        var p = folge("a", staffel: 1, 1, laufzeit: 20_000_000_000)
        p = p.nachWiedergabe(ticks: 6_000_000_000, wann: Date())
        #expect(!p.gesehen)
        #expect(p.stelleTicks == 6_000_000_000)
        #expect(p.fortsetzenAb == 600)
    }

    @Test("Unter 5 Prozent zaehlt nichts als Stelle")
    func zuFrueh() {
        var p = folge("a", staffel: 1, 1)
        p.stelleTicks = 500
        p = p.nachWiedergabe(ticks: 20, wann: Date())
        #expect(p.stelleTicks == nil)
    }

    @Test("Der Server zieht nach — ausser hier liegt ein neuerer Stand")
    func nachziehen() {
        let alt = Date(timeIntervalSince1970: 1_000)
        let neu = Date(timeIntervalSince1970: 2_000)
        let server = UserItemData(playbackPositionTicks: 300, played: false,
                                  lastPlayedDate: "1970-01-01T00:25:00.0000000Z")   // 1500
        var p = folge("a", staffel: 1, 1)
        p.zuletzt = alt
        let q = Downloadregeln.nachziehen(p, sehstand: server)
        #expect(q.stelleTicks == 300)
        #expect(q.zuletzt == Date(timeIntervalSince1970: 1_500))

        var hier = folge("a", staffel: 1, 1).nachWiedergabe(ticks: 950, wann: neu)
        hier = Downloadregeln.nachziehen(hier, sehstand: server)
        #expect(hier.gesehen, "der Stand von hier ist neuer und noch nicht gemeldet")
        #expect(Downloadregeln.nachziehen(p, sehstand: nil) == p)

        // Nach der Nachmeldung traegt der Server denselben Zeitpunkt, gerundet:
        // dann gilt wieder er.
        var gemeldet = folge("a", staffel: 1, 1).nachWiedergabe(ticks: 500, wann: Date(timeIntervalSince1970: 1_500.4))
        gemeldet = Downloadregeln.nachziehen(gemeldet, sehstand: server)
        #expect(gemeldet.stelleTicks == 300)
    }

    @Test("Der Sehstand kommt beim Anlegen mit")
    func anlegen() {
        let p = Downloadposten(id: "a", konto: "u1", art: .film, titel: "A", bytes: 1,
                               sehstand: UserItemData(playbackPositionTicks: 42, played: true,
                                                      lastPlayedDate: "2026-09-03T14:10:09.2201736Z"))
        #expect(p.gesehen)
        #expect(p.stelleTicks == 42)
        #expect(p.zuletzt != nil)
    }

    // MARK: Nachmeldung beim Wiederverbinden

    private func m(_ item: String, _ sek: TimeInterval, konto: String = "u1") -> Nachmeldung {
        Nachmeldung(itemID: item, konto: konto, ticks: 1, wann: Date(timeIntervalSince1970: sek))
    }

    @Test("Der neuere Zeitstempel gewinnt")
    func konflikt() {
        #expect(Nachmelderegeln.senden(m("a", 200), serverZuletzt: Date(timeIntervalSince1970: 100)))
        #expect(!Nachmelderegeln.senden(m("a", 100), serverZuletzt: Date(timeIntervalSince1970: 200)))
        #expect(!Nachmelderegeln.senden(m("a", 100), serverZuletzt: Date(timeIntervalSince1970: 100)))
        #expect(Nachmelderegeln.senden(m("a", 100), serverZuletzt: nil))
    }

    @Test("Geht eine Meldung doch durch, ist die liegende ueberholt — nur fuer dieses Konto")
    func ueberholt() {
        let ablage = [m("a", 1), m("a", 2, konto: "u2"), m("b", 3)]
        let rest = Nachmelderegeln.ueberholt(itemID: "a", konto: "u1", in: ablage)
        #expect(rest.map(\.id) == ["u2/a", "u1/b"])
    }

    @Test("LastPlayedDate wird als Text gelesen und bleibt mit jedem Decoder lesbar")
    func zeitpunkt() throws {
        let roh = #"{"PlaybackPositionTicks":5,"Played":true,"LastPlayedDate":"2026-09-03T14:10:09.2201736Z"}"#
        let d = try JSONDecoder().decode(UserItemData.self, from: Data(roh.utf8))
        let erwartet = ISO8601DateFormatter().date(from: "2026-09-03T14:10:09Z")!
        #expect(abs(d.zuletztGespielt!.timeIntervalSince(erwartet) - 0.22) < 0.01)
        // Ein Item mit Sehstand, mit dem gewoehnlichen Decoder wieder gelesen.
        let wieder = try JSONDecoder().decode(UserItemData.self, from: JSONEncoder().encode(d))
        #expect(wieder == d)
    }
}
