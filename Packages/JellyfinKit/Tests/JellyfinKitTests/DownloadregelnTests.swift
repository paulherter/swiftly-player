import Foundation
import Testing
@testable import JellyfinKit

@Suite("Downloadregeln")
struct DownloadregelnTests {

    // MARK: Bauhilfen

    private func posten(_ id: String,
                        stand: Downloadstand = .wartet,
                        bytes: Int64 = 1_000_000_000,
                        gesehen: Bool = false,
                        art: Downloadposten.Art = .film,
                        serie: String? = nil, serienId: String? = nil,
                        staffel: Int? = nil, folge: Int? = nil,
                        sekunden: TimeInterval = 0,
                        konto: String = "u1") -> Downloadposten {
        Downloadposten(id: id, konto: konto, art: art, titel: "Titel " + id,
                       serie: serie, serienId: serienId,
                       staffel: staffel, folge: folge,
                       container: "mkv", bytes: bytes,
                       stand: stand, gesehen: gesehen,
                       angelegt: Date(timeIntervalSince1970: 1_000_000 + sekunden))
    }

    // MARK: H4 — eins nach dem anderen

    @Test("Der aelteste Wartende ist dran")
    func aeltesterZuerst() {
        let liste = [posten("b", sekunden: 20), posten("a", sekunden: 10), posten("c", sekunden: 30)]
        #expect(Downloadregeln.naechster(aus: liste, imWLAN: true, nurUeberWLAN: true)?.id == "a")
    }

    @Test("Laeuft schon einer, faengt keiner an")
    func nurEinerGleichzeitig() {
        let liste = [posten("a", stand: .laedt), posten("b", sekunden: 10)]
        #expect(Downloadregeln.naechster(aus: liste, imWLAN: true, nurUeberWLAN: true) == nil)
    }

    @Test("Angehaltene und fehlgeschlagene faengt niemand von selbst an")
    func nurWartende() {
        let liste = [posten("a", stand: .angehalten), posten("b", stand: .fehler),
                     posten("c", stand: .fertig)]
        #expect(Downloadregeln.naechster(aus: liste, imWLAN: true, nurUeberWLAN: true) == nil)
    }

    @Test("Ohne WLAN wartet alles, wenn nur ueber WLAN geladen werden soll")
    func ohneWLAN() {
        let liste = [posten("a")]
        #expect(Downloadregeln.naechster(aus: liste, imWLAN: false, nurUeberWLAN: true) == nil)
        #expect(Downloadregeln.naechster(aus: liste, imWLAN: false, nurUeberWLAN: false)?.id == "a")
    }

    @Test("Gleiche Zeit: die Kennung entscheidet, nicht die Reihenfolge der Liste")
    func stabilBeiGleichstand() {
        let vorwaerts = [posten("a"), posten("b")]
        let rueckwaerts = [posten("b"), posten("a")]
        #expect(Downloadregeln.naechster(aus: vorwaerts, imWLAN: true, nurUeberWLAN: true)?.id
                == Downloadregeln.naechster(aus: rueckwaerts, imWLAN: true, nurUeberWLAN: true)?.id)
    }

    // MARK: H5

    @Test("Mobilfunk nur, wenn es erlaubt ist")
    func mobilfunk() {
        #expect(Downloadregeln.darfLaden(imWLAN: true,  nurUeberWLAN: true))
        #expect(Downloadregeln.darfLaden(imWLAN: true,  nurUeberWLAN: false))
        #expect(Downloadregeln.darfLaden(imWLAN: false, nurUeberWLAN: false))
        #expect(!Downloadregeln.darfLaden(imWLAN: false, nurUeberWLAN: true))
    }

    // MARK: H3 und H6 — Platz

    @Test("Reichlich Platz: es reicht, und es gibt nichts zu raeumen")
    func platzReicht() {
        let a = Downloadregeln.platz(fuer: 10_000_000_000, frei: 100_000_000_000, vorhanden: [])
        #expect(a.reicht)
        #expect(a.entbehrlich.isEmpty)
        #expect(a.reichtNachAufraeumen)
    }

    @Test("Die Reserve zaehlt mit: knapp daneben ist nicht knapp genug")
    func luftBleibtFrei() {
        // Genau so viel frei wie die Datei gross ist: ohne Reserve waere das
        // ein Treffer, mit Reserve fehlt genau die Reserve.
        let a = Downloadregeln.platz(fuer: 10_000_000_000, frei: 10_000_000_000, vorhanden: [])
        #expect(!a.reicht)
        #expect(a.freiDanach == -Downloadregeln.luft)
    }

    @Test("Gesehenes macht den Weg frei, Ungesehenes nicht")
    func aufraeumenReicht() {
        let vorhanden = [
            posten("alt", stand: .fertig, bytes: 8_000_000_000, gesehen: true),
            posten("neu", stand: .fertig, bytes: 9_000_000_000, gesehen: false),
        ]
        let a = Downloadregeln.platz(fuer: 10_000_000_000, frei: 5_000_000_000, vorhanden: vorhanden)
        #expect(!a.reicht)
        #expect(a.entbehrlich.map(\.id) == ["alt"])
        #expect(a.entbehrlichBytes == 8_000_000_000)
        // 5 - 10 - 1 = -6 GB; 8 GB entbehrlich deckt das.
        #expect(a.reichtNachAufraeumen)
    }

    @Test("Reicht auch nach dem Aufraeumen nicht")
    func aufraeumenReichtNicht() {
        let vorhanden = [posten("alt", stand: .fertig, bytes: 1_000_000_000, gesehen: true)]
        let a = Downloadregeln.platz(fuer: 60_000_000_000, frei: 5_000_000_000, vorhanden: vorhanden)
        #expect(!a.reicht)
        #expect(!a.reichtNachAufraeumen)
    }

    @Test("Angefangene Downloads gelten nie als entbehrlich")
    func angefangenesBleibt() {
        let vorhanden = [
            posten("halb", stand: .laedt, bytes: 9_000_000_000, gesehen: true),
            posten("wartet", stand: .wartet, bytes: 9_000_000_000, gesehen: true),
        ]
        #expect(Downloadregeln.entbehrlich(aus: vorhanden).isEmpty)
    }

    @Test("Entbehrliches steht mit dem groessten zuerst")
    func groesstesZuerst() {
        let vorhanden = [
            posten("klein", stand: .fertig, bytes: 2_000_000_000, gesehen: true),
            posten("gross", stand: .fertig, bytes: 20_000_000_000, gesehen: true),
            posten("mittel", stand: .fertig, bytes: 7_000_000_000, gesehen: true),
        ]
        #expect(Downloadregeln.entbehrlich(aus: vorhanden).map(\.id) == ["gross", "mittel", "klein"])
    }

    // MARK: H12 — eine Serie ist eine Zeile

    @Test("Folgen derselben Serie werden eine Gruppe, Filme bleiben einzeln")
    func serieWirdEineZeile() {
        let liste = [
            posten("f1", art: .folge, serie: "Fallout", serienId: "S1", staffel: 1, folge: 2, sekunden: 10),
            posten("f2", art: .folge, serie: "Fallout", serienId: "S1", staffel: 1, folge: 1, sekunden: 20),
            posten("film", sekunden: 5),
        ]
        let gruppen = Downloadregeln.gruppiert(liste)
        #expect(gruppen.count == 2)
        guard case let .serie(id, titel, folgen) = gruppen.first(where: { $0.id == "serie-S1" }) else {
            Issue.record("Serie fehlt"); return
        }
        #expect(id == "S1")
        #expect(titel == "Fallout")
        // Nach Staffel und Folge, nicht nach Zugang.
        #expect(folgen.map(\.id) == ["f2", "f1"])
    }

    @Test("Die Gruppe traegt die Summe und den juengsten Zugang")
    func gruppeRechnet() {
        let liste = [
            posten("f1", bytes: 2_000_000_000, art: .folge, serie: "X", serienId: "S", staffel: 1, folge: 1, sekunden: 10),
            posten("f2", bytes: 3_000_000_000, art: .folge, serie: "X", serienId: "S", staffel: 1, folge: 2, sekunden: 90),
        ]
        let g = Downloadregeln.gruppiert(liste)[0]
        #expect(g.bytes == 5_000_000_000)
        #expect(g.angelegt == Date(timeIntervalSince1970: 1_000_090))
    }

    @Test("Zwei Serien bleiben zwei Zeilen, neueste zuerst")
    func zweiSerien() {
        let liste = [
            posten("a", art: .folge, serie: "Alt", serienId: "A", staffel: 1, folge: 1, sekunden: 10),
            posten("b", art: .folge, serie: "Neu", serienId: "B", staffel: 1, folge: 1, sekunden: 900),
        ]
        #expect(Downloadregeln.gruppiert(liste).map(\.titel) == ["Neu", "Alt"])
    }

    @Test("Eine Folge ohne Serienkennung steht einzeln, nicht unter nil")
    func folgeOhneSerie() {
        let liste = [posten("waise", art: .folge, serie: "Irgendwas", serienId: nil)]
        let g = Downloadregeln.gruppiert(liste)
        #expect(g.count == 1)
        guard case .einzeln = g[0] else { Issue.record("haette einzeln stehen muessen"); return }
    }

    // MARK: Zahlen

    @Test("Belegung zaehlt nur, was fertig ist")
    func belegung() {
        let liste = [
            posten("a", stand: .fertig, bytes: 4_000_000_000),
            posten("b", stand: .laedt,  bytes: 9_000_000_000),
            posten("c", stand: .fertig, bytes: 1_000_000_000),
        ]
        let b = Downloadregeln.belegung(liste)
        #expect(b.anzahl == 2)
        #expect(b.bytes == 5_000_000_000)
    }

    @Test("Groesse rechnet in Tausenderstufen, wie der Finder")
    func groesseInGB() {
        // 18,6 GB in Tausenderstufen — nicht 17,3 GiB.
        let text = Downloadregeln.groesse(18_600_000_000)
        #expect(text.contains("18"))
        #expect(text.uppercased().contains("GB"))
    }

    @Test("Ohne Groesse vom Server gibt es keinen Anteil")
    func keinAnteilOhneGroesse() {
        var p = posten("a", bytes: 0)
        p.geladen = 500
        #expect(p.anteil == nil)
        var q = posten("b", bytes: 1000)
        q.geladen = 250
        #expect(q.anteil == 0.25)
    }

    @Test("Der Dateiname traegt Konto, Kennung und Endung")
    func dateiname() {
        let p = posten("abc", konto: "u9")
        #expect(p.dateiname == "u9-abc.mkv")
        // Zwei Konten, dieselbe Kennung — zwei Dateien. H11.
        #expect(posten("abc", konto: "u1").dateiname != posten("abc", konto: "u2").dateiname)
    }

    // MARK: H8 — der Plan von der Platte

    @Test("Eine Datei vom Geraet ist Direct Play, ohne Sitzung und ohne Grund")
    func planVonDerPlatte() {
        let datei = URL(fileURLWithPath: "/tmp/u1-abc.mkv")
        let plan = PlaybackPlan.vonDerPlatte(datei, container: "mkv", mediaSourceID: "q1")
        #expect(plan.url == datei)
        #expect(plan.method == .directPlay)
        #expect(plan.isLossless)
        // Es *ist* die unveraenderte Datei — es kann keinen Grund geben.
        #expect(plan.reasons.isEmpty)
        // Ohne Server keine Sitzung.
        #expect(plan.playSessionID == nil)
        #expect(plan.container == "mkv")
        #expect(plan.mediaSourceID == "q1")
    }

    // MARK: Das Format traegt ueber die Zeit

    @Test("Woertliches JSON — ein umbenanntes Feld faellt hier auf")
    func formatBleibt() throws {
        let roh = """
        {
          "id": "12ab",
          "konto": "u1",
          "art": "folge",
          "titel": "The End",
          "serie": "Fallout",
          "serienId": "S1",
          "staffel": 1,
          "folge": 1,
          "laufzeitTicks": 38400000000,
          "container": "mkv",
          "quelle": "q1",
          "bytes": 2800000000,
          "geladen": 1400000000,
          "stand": "laedt",
          "gesehen": false,
          "angelegt": 757382400,
          "nochAufDemServer": true
        }
        """
        let p = try JSONDecoder().decode(Downloadposten.self, from: Data(roh.utf8))
        #expect(p.id == "12ab")
        #expect(p.konto == "u1")
        #expect(p.art == .folge)
        #expect(p.serienId == "S1")
        #expect(p.bytes == 2_800_000_000)
        #expect(p.geladen == 1_400_000_000)
        #expect(p.stand == .laedt)
        #expect(p.anteil == 0.5)
        #expect(p.nochAufDemServer)
        #expect(p.dateiname == "u1-12ab.mkv")
    }

    @Test("Ein alter Eintrag ohne die spaeteren Felder ist kein Fehler")
    func aeltereAblage() throws {
        // `grund` fehlt — das ist der Normalfall, solange nichts schiefging.
        let roh = """
        {"id":"a","konto":"u1","art":"film","titel":"T","bytes":1,
         "geladen":0,"stand":"wartet","gesehen":false,
         "angelegt":757382400,"nochAufDemServer":true}
        """
        let p = try JSONDecoder().decode(Downloadposten.self, from: Data(roh.utf8))
        #expect(p.grund == nil)
        #expect(p.serie == nil)
        #expect(p.dateiname == "u1-a")
    }
}

@Suite("Nachmeldung")
struct NachmeldungTests {

    private func m(_ item: String, _ ticks: Int64, _ sek: TimeInterval,
                   konto: String = "u1") -> Nachmeldung {
        Nachmeldung(itemID: item, konto: konto, ticks: ticks,
                    wann: Date(timeIntervalSince1970: 1_000_000 + sek))
    }

    @Test("Eine Angabe je Titel — die neueste gilt")
    func neueGewinnt() {
        var a: [Nachmeldung] = []
        a = Nachmelderegeln.aufnehmen(m("f1", 100, 10), in: a)
        a = Nachmelderegeln.aufnehmen(m("f1", 900, 20), in: a)
        #expect(a.count == 1)
        #expect(a[0].ticks == 900)
    }

    @Test("Eine nachtraeglich hereinkommende alte Meldung ueberschreibt nicht")
    func aeltereVerliert() {
        var a: [Nachmeldung] = []
        a = Nachmelderegeln.aufnehmen(m("f1", 900, 20), in: a)
        a = Nachmelderegeln.aufnehmen(m("f1", 100, 10), in: a)
        #expect(a[0].ticks == 900)
    }

    @Test("Zwei Konten teilen sich keinen Stand")
    func kontenGetrennt() {
        var a: [Nachmeldung] = []
        a = Nachmelderegeln.aufnehmen(m("f1", 100, 10, konto: "u1"), in: a)
        a = Nachmelderegeln.aufnehmen(m("f1", 900, 20, konto: "u2"), in: a)
        #expect(a.count == 2)
        #expect(Nachmelderegeln.faellig(a, konto: "u1").map(\.ticks) == [100])
        #expect(Nachmelderegeln.faellig(a, konto: "u2").map(\.ticks) == [900])
    }

    @Test("Faellig kommt aelteste zuerst")
    func reihenfolge() {
        var a: [Nachmeldung] = []
        a = Nachmelderegeln.aufnehmen(m("b", 1, 30), in: a)
        a = Nachmelderegeln.aufnehmen(m("a", 1, 10), in: a)
        #expect(Nachmelderegeln.faellig(a, konto: "u1").map(\.itemID) == ["a", "b"])
    }

    @Test("Erledigtes faellt heraus, der Rest bleibt")
    func erledigt() {
        var a: [Nachmeldung] = []
        a = Nachmelderegeln.aufnehmen(m("a", 1, 10), in: a)
        a = Nachmelderegeln.aufnehmen(m("b", 1, 20), in: a)
        let rest = Nachmelderegeln.erledigt(["u1/a"], in: a)
        #expect(rest.map(\.itemID) == ["b"])
    }

    @Test("Woertliches JSON — das Format traegt ueber die Zeit")
    func format() throws {
        let roh = """
        {"itemID":"abc","konto":"u1","ticks":123456789,"wann":757382400}
        """
        let n = try JSONDecoder().decode(Nachmeldung.self, from: Data(roh.utf8))
        #expect(n.itemID == "abc")
        #expect(n.ticks == 123_456_789)
        #expect(n.id == "u1/abc")
    }
}
