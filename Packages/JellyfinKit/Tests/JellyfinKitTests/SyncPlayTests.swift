import Foundation
import Testing
@testable import JellyfinKit

@Suite("SyncPlay: Nachrichten, Uhren, Befehle")
struct SyncPlayTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Nachrichten lesen — Wortlaut wie vom Server (openapi 12.1)

    @Test func befehlMitSiebenNachkommastellen() throws {
        let text = """
        {"MessageType":"SyncPlayCommand","MessageId":"x","Data":{"GroupId":"g1",\
        "PlaylistItemId":"p1","When":"2026-09-24T10:00:01.5000000Z","PositionTicks":123450000,\
        "Command":"Unpause","EmittedAt":"2026-09-24T10:00:00.9000000Z"}}
        """
        guard case let .befehl(b)? = SyncPlayNachricht.lesen(text) else {
            Issue.record("kein Befehl"); return
        }
        #expect(b.art == .weiter)
        #expect(b.gruppe == "g1")
        #expect(b.eintrag == "p1")
        #expect(abs((b.stelle ?? 0) - 12.345) < 0.0001)
        let erwartet = try #require(SyncPlay.zeitLesen("2026-09-24T10:00:01.500Z"))
        #expect(abs(b.wann.timeIntervalSince(erwartet)) < 0.002)
    }

    @Test func gruppenNeuigkeiten() {
        func update(_ art: String, _ daten: String) -> SyncPlayNachricht? {
            SyncPlayNachricht.lesen(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g1","Type":"\#(art)","Data":\#(daten)}}"#)
        }
        #expect(update("UserJoined", #""Tom""#) == .jemandKam("Tom"))
        #expect(update("UserLeft", #""Tom""#) == .jemandGing("Tom"))
        #expect(update("GroupLeft", #""g1""#) == .verlassen)
        #expect(update("NotInGroup", #""""#) == .nichtInGruppe)
        #expect(update("LibraryAccessDenied", #""""#) == .keinZugriff)
        #expect(update("StateUpdate", #"{"State":"Waiting","Reason":"Buffer"}"#)
                == .zustand(.wartet, grund: "Buffer"))

        let beitritt = update("GroupJoined", #"{"GroupId":"g1","GroupName":"Filmabend","State":"Idle","Participants":["Paul"],"LastUpdatedAt":"2026-09-24T10:00:00.1234567Z"}"#)
        guard case let .beigetreten(g)? = beitritt else { Issue.record("kein Beitritt"); return }
        #expect(g.name == "Filmabend")
        #expect(g.zustand == .leer)
        #expect(g.teilnehmer == ["Paul"])
        #expect(g.stand != nil)
    }

    @Test func warteschlange() {
        let text = #"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g1","Type":"PlayQueue","Data":{"Reason":"NewPlaylist","LastUpdate":"2026-09-24T10:00:00Z","Playlist":[{"ItemId":"i1","PlaylistItemId":"p1"},{"ItemId":"i2","PlaylistItemId":"p2"}],"PlayingItemIndex":1,"StartPositionTicks":600000000,"IsPlaying":false,"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}}"#
        guard case let .warteschlange(w)? = SyncPlayNachricht.lesen(text) else {
            Issue.record("keine Warteschlange"); return
        }
        #expect(w.aktuell == .init(titel: "i2", eintrag: "p2"))
        #expect(w.startstelle == 60)
        #expect(w.wechseltTitel)
        #expect(!w.laeuft)
    }

    @Test func fremdesBleibtLiegen() {
        #expect(SyncPlayNachricht.lesen(#"{"MessageType":"ForceKeepAlive","Data":60}"#) == nil)
        #expect(SyncPlayNachricht.lesen("kein json") == nil)
        #expect(SyncPlayNachricht.lesen(#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g","Type":"Neu","Data":1}}"#) == nil)
    }

    @Test func gruppenlisteOhneFelder() throws {
        let roh = #"[{"GroupId":"g1","GroupName":"Filmabend","State":"Playing","Participants":["Paul","Tom","Paul"]},{"GroupId":"g2"}]"#
        let liste = try JSONDecoder().decode([SyncPlayGruppe].self, from: Data(roh.utf8))
        #expect(liste.count == 2)
        #expect(liste[0].zustand == .laeuft)
        #expect(liste[0].andere(als: "Paul") == ["Tom", "Paul"], "das zweite Geraet desselben Kontos bleibt")
        #expect(liste[1].name == "")
        #expect(liste[1].teilnehmer.isEmpty)
    }

    @Test func andereOhneMichUndOhneDoppelte() {
        let g = SyncPlayGruppe(id: "g", name: "n", teilnehmer: ["Paul", "Tom", "Tom", "Lena"])
        #expect(g.andere(als: "Paul") == ["Tom", "Lena"])
        #expect(g.andere(als: nil) == ["Paul", "Tom", "Lena"])
    }

    // MARK: Uhren

    private func messung(versatz: TimeInterval, hin: TimeInterval, zurueck: TimeInterval,
                         ab: Date) -> Zeitabgleich.Messung {
        // Server rechnet 5 ms.
        let rein = ab.addingTimeInterval(hin + versatz)
        let raus = rein.addingTimeInterval(0.005)
        return .init(gesendet: ab, serverEmpfangen: rein, serverGesendet: raus,
                     empfangen: raus.addingTimeInterval(-versatz + zurueck))
    }

    @Test func versatzAusSymmetrischerMessung() {
        let m = messung(versatz: 2.5, hin: 0.04, zurueck: 0.04, ab: t0)
        #expect(abs(m.versatz - 2.5) < 0.0001)
        #expect(abs(m.laufzeit - 0.08) < 0.0001)
    }

    @Test func kuerzesteLaufzeitGilt() {
        var a = Zeitabgleich()
        #expect(!a.bereit)
        #expect(a.versatz == 0)
        // Eine lange, schiefe Messung und eine kurze.
        a.aufnehmen(messung(versatz: 1, hin: 0.4, zurueck: 0.02, ab: t0))
        a.aufnehmen(messung(versatz: 1, hin: 0.01, zurueck: 0.01, ab: t0))
        #expect(abs(a.versatz - 1) < 0.001)
        #expect(a.pingMillisekunden == 10)
        let lokal = t0.addingTimeInterval(10)
        #expect(abs(a.lokal(a.server(lokal)).timeIntervalSince(lokal)) < 0.0001)
    }

    @Test func nurAchtMessungenBleiben() {
        var a = Zeitabgleich()
        for i in 0..<12 { a.aufnehmen(messung(versatz: Double(i), hin: 0.01, zurueck: 0.01, ab: t0)) }
        #expect(a.messungen.count == Zeitabgleich.behalten)
        #expect(Zeitabgleich.pause(nachMessungen: 0) == 1)
        #expect(Zeitabgleich.pause(nachMessungen: 3) == 60)
    }

    // MARK: Befehle ausführen

    private func abgleich(versatz: TimeInterval) -> Zeitabgleich {
        var a = Zeitabgleich()
        a.aufnehmen(messung(versatz: versatz, hin: 0.01, zurueck: 0.01, ab: t0))
        return a
    }

    private func befehl(_ art: SyncPlayBefehl.Art, wann: Date, stelle: Double?) -> SyncPlayBefehl {
        .init(gruppe: "g", eintrag: "p", art: art, wann: wann, stelle: stelle)
    }

    @Test func weiterInDerZukunftWartet() {
        // Serveruhr geht 3 s vor. Befehl gilt in 1,5 s Serverzeit ab jetzt.
        let a = abgleich(versatz: 3)
        let jetzt = t0
        let b = befehl(.weiter, wann: a.server(jetzt).addingTimeInterval(1.5), stelle: 100)
        let x = SyncPlayAusfuehrung.fuer(b, jetzt: jetzt, abgleich: a, lokaleStelle: 100.1)
        #expect(x.schritt == .weiter)
        #expect(abs(x.warten - 1.5) < 0.001)
        #expect(x.stelle == nil, "100 ms daneben ist kein Sprung")

        let y = SyncPlayAusfuehrung.fuer(b, jetzt: jetzt, abgleich: a, lokaleStelle: 90)
        #expect(y.stelle == 100)
    }

    @Test func weiterInDerVergangenheitHoltAuf() {
        let a = abgleich(versatz: -2)
        let jetzt = t0
        // Vor vier Sekunden (Serverzeit) bei 100 gestartet.
        let b = befehl(.weiter, wann: a.server(jetzt).addingTimeInterval(-4), stelle: 100)
        let x = SyncPlayAusfuehrung.fuer(b, jetzt: jetzt, abgleich: a, lokaleStelle: 100)
        #expect(x.warten == 0)
        #expect(abs((x.stelle ?? 0) - 104) < 0.001)
    }

    @Test func pauseSpringtAufDieStelleDerGruppe() {
        let a = abgleich(versatz: 0)
        let x = SyncPlayAusfuehrung.fuer(befehl(.pause, wann: t0.addingTimeInterval(0.3), stelle: 50),
                                         jetzt: t0, abgleich: a, lokaleStelle: 51)
        #expect(x.schritt == .pause)
        #expect(x.stelle == 50)
        #expect(abs(x.warten - 0.3) < 0.001)
    }

    @Test func springenImmerMitStelle() {
        let a = abgleich(versatz: 0)
        let x = SyncPlayAusfuehrung.fuer(befehl(.springen, wann: t0.addingTimeInterval(-1), stelle: 600),
                                         jetzt: t0, abgleich: a, lokaleStelle: 600)
        #expect(x == .init(schritt: .springen, stelle: 600, warten: 0))
        let s = SyncPlayAusfuehrung.fuer(befehl(.stopp, wann: t0, stelle: nil),
                                         jetzt: t0, abgleich: a, lokaleStelle: 1)
        #expect(s.schritt == .stopp)
    }

    @Test func nachfuehrenErstAbEinerSekunde() {
        let a = abgleich(versatz: 0)
        let b = befehl(.weiter, wann: t0, stelle: 10)
        let jetzt = t0.addingTimeInterval(20)   // Gruppe bei 30
        #expect(SyncPlayAusfuehrung.nachfuehren(letzter: b, eintrag: "p", jetzt: jetzt,
                                                abgleich: a, lokaleStelle: 29.5) == nil)
        let soll = SyncPlayAusfuehrung.nachfuehren(letzter: b, eintrag: "p", jetzt: jetzt,
                                                   abgleich: a, lokaleStelle: 27)
        #expect(abs((soll ?? 0) - 30) < 0.001)
        // Anderer Eintrag, Pause, oder noch nicht fällig: nie.
        #expect(SyncPlayAusfuehrung.nachfuehren(letzter: b, eintrag: "anders", jetzt: jetzt,
                                                abgleich: a, lokaleStelle: 0) == nil)
        #expect(SyncPlayAusfuehrung.nachfuehren(letzter: befehl(.pause, wann: t0, stelle: 10),
                                                eintrag: "p", jetzt: jetzt, abgleich: a,
                                                lokaleStelle: 0) == nil)
        #expect(SyncPlayAusfuehrung.nachfuehren(letzter: b, eintrag: "p", jetzt: t0.addingTimeInterval(-1),
                                                abgleich: a, lokaleStelle: 0) == nil)
    }

    // MARK: Puffern

    @Test func pufferwaechter() {
        var w = Pufferwaechter()
        var t = t0
        #expect(w.takt(stelle: 10, sollLaufen: true, jetzt: t) == nil)
        t += 1; #expect(w.takt(stelle: 11, sollLaufen: true, jetzt: t) == nil)
        // Steht.
        t += 1; #expect(w.takt(stelle: 11, sollLaufen: true, jetzt: t) == nil)
        t += 1; #expect(w.takt(stelle: 11, sollLaufen: true, jetzt: t) == nil)
        t += 1; #expect(w.takt(stelle: 11, sollLaufen: true, jetzt: t) == nil)
        t += 1; #expect(w.takt(stelle: 11, sollLaufen: true, jetzt: t) == .puffert)
        t += 1; #expect(w.takt(stelle: 11, sollLaufen: true, jetzt: t) == nil, "nur einmal")
        t += 1; #expect(w.takt(stelle: 11.5, sollLaufen: true, jetzt: t) == .bereit)
        // Angehalten zählt nicht als Puffern.
        for _ in 0..<5 { t += 1; #expect(w.takt(stelle: 11.5, sollLaufen: false, jetzt: t) == nil) }
    }

    @Test func bereitNachDemSprung() {
        #expect(SyncPlayAusfuehrung.bereitStelle(ziel: 600, ist: 600.3) == 600)
        #expect(SyncPlayAusfuehrung.bereitStelle(ziel: 600, ist: 599.2) == 600)
        #expect(SyncPlayAusfuehrung.bereitStelle(ziel: 600, ist: 604) == 604)
    }

    @Test func zeitTextLiestDerServer() throws {
        let text = SyncPlay.zeitText(t0.addingTimeInterval(0.25))
        #expect(text.hasSuffix("Z"))
        #expect(text.contains(".250"))
        let zurueck = try #require(SyncPlay.zeitLesen(text))
        #expect(abs(zurueck.timeIntervalSince(t0) - 0.25) < 0.001)
    }

    @Test func tickumrechnung() {
        #expect(SyncPlay.ticks(1.5) == 15_000_000)
        #expect(SyncPlay.sekunden(600_000_000) == 60)
        #expect(SyncPlayRecht(rawValue: "JoinGroups")?.darfAnlegen == false)
        #expect(SyncPlayRecht(rawValue: "JoinGroups")?.darfBeitreten == true)
        #expect(SyncPlayRecht.keins.darfBeitreten == false)
    }
}
