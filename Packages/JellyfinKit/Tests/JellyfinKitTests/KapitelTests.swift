import Foundation
import Testing
@testable import JellyfinKit

@Suite("Kapitel einlesen")
struct KapitelEinlesenTests {

    /// Die Form von `ChapterInfo` am Titel, wie sie mit `Fields=Chapters`
    /// kommt — die Felder aus der OpenAPI-Beschreibung.
    private let antwort = """
    { "Id": "f1", "Name": "Film",
      "Chapters": [
        { "StartPositionTicks": 0, "Name": "Prolog",
          "ImageDateModified": "0001-01-01T00:00:00.0000000Z" },
        { "StartPositionTicks": 4235000000, "Name": "  Der Überfall ",
          "ImageTag": "abc", "ImageDateModified": "2026-01-01T00:00:00.0000000Z" },
        { "StartPositionTicks": 31500000000 }
      ] }
    """.data(using: .utf8)!

    @Test("Ticks werden zu Sekunden, Namen ohne Rand")
    func einlesen() throws {
        let k = try JSONDecoder().decode(KapitelAntwort.self, from: antwort).kapitel
        #expect(k.count == 3)
        #expect(k[0] == Kapitel(name: "Prolog", von: 0))
        #expect(k[1] == Kapitel(name: "Der Überfall", von: 423.5))
        // Ohne Namen ein leerer, kein Fehler.
        #expect(k[2] == Kapitel(name: "", von: 3150))
    }

    @Test("Ohne Kapitel am Titel: leer, kein Fehler")
    func ohne() throws {
        let d = #"{ "Id": "f1", "Name": "Film" }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(KapitelAntwort.self, from: d).kapitel.isEmpty)
        let n = #"{ "Chapters": null }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(KapitelAntwort.self, from: n).kapitel.isEmpty)
    }

    @Test("Ein Kapitel ohne Anfang fällt weg, die anderen bleiben")
    func ohneAnfang() throws {
        let d = #"{ "Chapters": [ { "Name": "Kaputt" }, { "StartPositionTicks": "neun" },"#
            + #" { "StartPositionTicks": 600000000, "Name": "Echt" }, 42, null ] }"#
        let k = try JSONDecoder().decode(KapitelAntwort.self, from: Data(d.utf8)).kapitel
        #expect(k == [Kapitel(name: "Echt", von: 60)])
    }
}

@Suite("Welche Kapitel die Leiste gliedern")
struct KapitelBrauchbarTests {

    private func k(_ von: Double, _ name: String = "") -> Kapitel { Kapitel(name: name, von: von) }

    @Test("Sortiert und ohne doppelte Anfänge — das erste gilt")
    func sortiert() {
        let roh = [k(900, "C"), k(0, "A"), k(300, "B"), k(300, "B2")]
        #expect(Kapitelleiste.brauchbar(roh).map(\.name) == ["A", "B", "C"])
    }

    @Test("Ein einziges Kapitel teilt nichts")
    func einzeln() {
        #expect(Kapitelleiste.brauchbar([k(0, "Film")]).isEmpty)
        #expect(Kapitelleiste.brauchbar([]).isEmpty)
    }

    @Test("Unsinn fällt weg, bevor gezählt wird")
    func unsinn() {
        #expect(Kapitelleiste.brauchbar([k(-5), k(.nan), k(.infinity), k(60)]).isEmpty)
        #expect(Kapitelleiste.brauchbar([k(-5), k(0), k(60)]).map(\.von) == [0, 60])
    }

    @Test("Das Platzhalterraster des Servers gliedert nichts")
    func raster() {
        // DummyChapterDuration = 300: alle fünf Minuten eins, ab 0.
        let platzhalter = (0..<9).map { k(Double($0) * 300, "Kapitel \($0 + 1)") }
        #expect(Kapitelleiste.brauchbar(platzhalter).isEmpty)
    }

    @Test("Echte Kapitel liegen nie auf die Sekunde gleich weit — sie bleiben")
    func echteKapitel() {
        let scheibe = [k(0), k(312.4), k(655.1), k(1020.8), k(1301)]
        #expect(Kapitelleiste.brauchbar(scheibe).count == 5)
    }

    @Test("Ein gleichmäßiges Raster, das nicht bei 0 anfängt, ist keins vom Server")
    func rasterNichtAbNull() {
        #expect(Kapitelleiste.brauchbar([k(90), k(390), k(690)]).count == 3)
    }

    @Test("Ein Raster mit kleinen Abweichungen bleibt ein Raster")
    func rasterMitSpiel() {
        #expect(Kapitelleiste.brauchbar([k(0), k(300.2), k(600), k(900.3)]).isEmpty)
    }

    @Test("Zwei Kapitel sind noch kein Raster")
    func zweiKapitel() {
        #expect(Kapitelleiste.brauchbar([k(0), k(300)]).count == 2)
    }
}

@Suite("Die geteilte Leiste")
struct KapitelleisteTests {

    private typealias Stueck = Kapitelleiste.Stueck

    @Test("Grenzen: ohne den Anfang bei 0 und ohne alles ab dem Ende")
    func grenzen() {
        let kapitel = [Kapitel(name: "A", von: 0), Kapitel(name: "B", von: 600),
                       Kapitel(name: "C", von: 1800), Kapitel(name: "D", von: 3000)]
        #expect(Kapitelleiste.grenzen(kapitel, dauer: 2400) == [600, 1800])
        // Solange VLC die Dauer nicht kennt, wird nicht geschnitten.
        #expect(Kapitelleiste.grenzen(kapitel, dauer: 0).isEmpty)
    }

    @Test("Ohne Grenzen ist die Leiste ein Stück — wie vorher")
    func ohneGrenzen() {
        let ganz = [Stueck(von: 0, bis: 1)]
        #expect(Kapitelleiste.stuecke(grenzen: [], dauer: 2400, breite: 300, mindestbreite: 8) == ganz)
        #expect(Kapitelleiste.stuecke(grenzen: [600], dauer: 0, breite: 300, mindestbreite: 8) == ganz)
        #expect(Kapitelleiste.stuecke(grenzen: [600], dauer: 2400, breite: 0, mindestbreite: 8) == ganz)
    }

    @Test("Jede Grenze ein Schnitt, als Anteil")
    func schnitte() {
        let s = Kapitelleiste.stuecke(grenzen: [1800, 600], dauer: 2400, breite: 300, mindestbreite: 8)
        #expect(s == [Stueck(von: 0, bis: 0.25), Stueck(von: 0.25, bis: 0.75), Stueck(von: 0.75, bis: 1)])
    }

    @Test("Zu enge Schnitte fallen weg, das Stück davor reicht weiter")
    func zuEng() {
        // 300 Punkt für 3000 s: ein Punkt sind zehn Sekunden, acht Punkt 80 s.
        let s = Kapitelleiste.stuecke(grenzen: [600, 650, 700, 2960], dauer: 3000,
                                      breite: 300, mindestbreite: 8)
        // 650 läge 5 Punkt hinter 600, fällt weg; 700 läge 10 dahinter, bleibt.
        // 2960 ließe am Ende nur 4 Punkt.
        #expect(s.map(\.von) == [0, 0.2, 700.0 / 3000])
        #expect(s.last?.bis == 1)
    }

    @Test("Die Lücke geht je zur Hälfte ab, an den Enden nichts")
    func rahmen() {
        let s = Kapitelleiste.stuecke(grenzen: [100], dauer: 400, breite: 200, mindestbreite: 8)
        let links = s[0].rahmen(breite: 200, luecke: 2)
        let rechts = s[1].rahmen(breite: 200, luecke: 2)
        #expect(links.x == 0 && links.breite == 49)
        #expect(rechts.x == 51 && rechts.breite == 149)
        let ganz = Stueck(von: 0, bis: 1).rahmen(breite: 200, luecke: 2)
        #expect(ganz.x == 0 && ganz.breite == 200)
        // In der Mitte geht von beiden Seiten etwas ab.
        let mitte = Stueck(von: 0.25, bis: 0.75).rahmen(breite: 200, luecke: 2)
        #expect(mitte.x == 51 && mitte.breite == 98)
    }

    @Test("Eingerastet wird nur an Schnitten mit Platz auf beiden Seiten")
    func fangschnitte() {
        // 300 Punkt für 3000 s; nötig sind 4 × 8 = 32 Punkt je Nachbarstück.
        let s = Kapitelleiste.stuecke(grenzen: [600, 900, 1100, 2000], dauer: 3000,
                                      breite: 300, mindestbreite: 8)
        #expect(s.count == 5)
        // Die Stücke sind 60, 30, 20, 90 und 100 Punkt breit. Gezeichnet
        // werden alle Schnitte; fangen darf nur der bei 2000 — jeder andere
        // hat auf einer Seite ein Stück unter 32 Punkt.
        #expect(Kapitelleiste.fangschnitte(s, dauer: 3000, breite: 300) == [2000])
        #expect(Kapitelleiste.fangschnitte([Stueck(von: 0, bis: 1)], dauer: 3000, breite: 300).isEmpty)
    }

    @Test("Dreissig Kapitel auf schmaler Leiste: gezeichnet, aber kein Einrasten")
    func dichteKapitel() {
        let grenzen = (1..<30).map { Double($0) * 240 }   // 2 h, alle 4 min
        let s = Kapitelleiste.stuecke(grenzen: grenzen, dauer: 7200, breite: 280, mindestbreite: 8)
        #expect(s.count == 30)
        #expect(Kapitelleiste.fangschnitte(s, dauer: 7200, breite: 280).isEmpty)
    }

    @Test("Eine Grenze gehört zum Stück, das dort anfängt")
    func stueckBei() {
        let s = [Stueck(von: 0, bis: 0.25), Stueck(von: 0.25, bis: 1)]
        #expect(Kapitelleiste.stueck(bei: 0, in: s) == 0)
        #expect(Kapitelleiste.stueck(bei: 0.2499, in: s) == 0)
        #expect(Kapitelleiste.stueck(bei: 0.25, in: s) == 1)
        #expect(Kapitelleiste.stueck(bei: 1, in: s) == 1)
        #expect(Kapitelleiste.stueck(bei: .nan, in: s) == nil)
        #expect(Kapitelleiste.stueck(bei: 0.5, in: []) == nil)
    }

    @Test("Das Kapitel an einer Stelle — vor dem ersten keins")
    func kapitelBei() {
        let kapitel = [Kapitel(name: "Anfang", von: 30), Kapitel(name: "Mitte", von: 600)]
        #expect(Kapitelleiste.kapitel(bei: 10, in: kapitel) == nil)
        #expect(Kapitelleiste.kapitel(bei: 30, in: kapitel)?.name == "Anfang")
        #expect(Kapitelleiste.kapitel(bei: 599.9, in: kapitel)?.name == "Anfang")
        #expect(Kapitelleiste.kapitel(bei: 4000, in: kapitel)?.name == "Mitte")
    }

    @Test("Eingerastet auf einem Schnitt heisst: das Kapitel, das dort anfängt")
    func eingerastetNenntDasRichtige() {
        // Über den Anteil zurückgerechnet landet die Stelle oft knapp davor.
        let kapitel = [Kapitel(name: "A", von: 0), Kapitel(name: "B", von: 1234.567)]
        for dauer in [2468.9, 3000.1, 5423.77, 7199.3] {
            let s = Kapitelleiste.stuecke(grenzen: Kapitelleiste.grenzen(kapitel, dauer: dauer),
                                          dauer: dauer, breite: 600, mindestbreite: 8)
            let schnitt = Kapitelleiste.fangschnitte(s, dauer: dauer, breite: 600)[0]
            #expect(Kapitelleiste.kapitel(bei: schnitt, in: kapitel)?.name == "B")
            #expect(Kapitelleiste.kapitel(bei: dauer * (schnitt / dauer), in: kapitel)?.name == "B")
        }
        #expect(Kapitelleiste.kapitel(bei: 1234.567 - 1e-9, in: kapitel)?.name == "B")
        #expect(Kapitelleiste.kapitel(bei: 1234.5, in: kapitel)?.name == "A")
    }

    @Test("Ein weggefallener Schnitt nimmt dem Kapitel nicht den Namen")
    func nameTrotzZuEng() {
        let kapitel = [Kapitel(name: "A", von: 0), Kapitel(name: "B", von: 600),
                       Kapitel(name: "C", von: 650)]
        let s = Kapitelleiste.stuecke(grenzen: Kapitelleiste.grenzen(kapitel, dauer: 3000),
                                      dauer: 3000, breite: 300, mindestbreite: 8)
        #expect(s.count == 2)
        #expect(Kapitelleiste.kapitel(bei: 660, in: kapitel)?.name == "C")
    }
}
