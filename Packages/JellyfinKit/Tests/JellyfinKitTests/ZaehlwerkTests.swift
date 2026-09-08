import Foundation
import Testing
@testable import JellyfinKit

@Suite("Zaehlwerk")
struct ZaehlwerkTests {

    private func roh(gezeigt: UInt64 = 0, dekodiert: UInt64 = 0,
                     gelesen: UInt64 = 0, entpackt: UInt64 = 0) -> Zaehlwerk.Rohwerte {
        .init(gelesen: gelesen, entpackt: entpackt, gezeigt: gezeigt, videoBloecke: dekodiert)
    }

    @Test("Speicherschrott wird nicht als Messung ausgegeben")
    func schrottAbgewiesen() {
        // `statistics` liefert die Struktur auch dann, wenn das Medium noch
        // keine hat; die Felder stehen dann auf dem, was zufaellig im
        // Speicher lag.
        var r = roh()
        r.gezeigt = Zaehlwerk.grenze + 1
        #expect(Zaehlwerk(r, stelle: 0, laeuft: true) == nil)
    }

    @Test("Vor dem Mindestfenster wird nichts gemeldet")
    func zuFrueh() {
        let start = Date()
        let a = Zaehlwerk(roh(gezeigt: 0), stelle: 0, laeuft: true, jetzt: start)!
        let b = Zaehlwerk(roh(gezeigt: 48), stelle: 2, laeuft: true, vorher: a,
                          jetzt: start.addingTimeInterval(2))!
        // Zwei Sekunden sind rund achtundvierzig Bilder — und trotzdem kein
        // Messwert: ein kurzes Fenster faengt VLCs Schuebe zufaellig.
        #expect(b.zeigtProSekunde == nil)
        #expect(b.laufAnteil == nil)
    }

    @Test("Ueber dem Mindestfenster stimmen die Raten")
    func rateStimmt() {
        let start = Date()
        let a = Zaehlwerk(roh(gezeigt: 0, dekodiert: 0), stelle: 0, laeuft: true, jetzt: start)!
        let b = Zaehlwerk(roh(gezeigt: 240, dekodiert: 240), stelle: 10, laeuft: true,
                          vorher: a, jetzt: start.addingTimeInterval(10))!
        #expect(abs((b.zeigtProSekunde ?? 0) - 24) < 0.001)
        #expect(abs((b.dekodiertProSekunde ?? 0) - 24) < 0.001)
        // Zehn Sekunden Film in zehn Sekunden Uhr: Echtzeit.
        #expect(abs((b.laufAnteil ?? 0) - 1) < 0.001)
    }

    @Test("Haengen zeigt sich am Lauf, nicht an den gezeigten Bildern")
    func haengenSichtbar() {
        // Der eigentliche Grund fuer `laufAnteil`: VLC zeichnet ein stehendes
        // Bild neu und zaehlt jede Wiederholung mit — beim Haengen laeuft
        // `gezeigt` also *schneller*. Am 08.09.2026 standen so 1015 gezeigte
        // Bilder bei Stelle 0:28, wo 671 hingehoert haetten.
        let start = Date()
        let a = Zaehlwerk(roh(gezeigt: 0), stelle: 0, laeuft: true, jetzt: start)!
        let b = Zaehlwerk(roh(gezeigt: 1015), stelle: 28, laeuft: true, vorher: a,
                          jetzt: start.addingTimeInterval(28))!
        #expect((b.zeigtProSekunde ?? 0) > 30)     // sieht gesund aus
        #expect((b.laufAnteil ?? 0) == 1)          // und ist es hier auch
        // Bleibt die Stelle zurueck, sagt es allein der Lauf.
        let c = Zaehlwerk(roh(gezeigt: 2000), stelle: 42, laeuft: true, vorher: a,
                          jetzt: start.addingTimeInterval(56))!
        #expect((c.laufAnteil ?? 0) < 0.8)
    }

    @Test("Ein Sprung setzt das Fenster zurueck")
    func sprungSetztZurueck() {
        let start = Date()
        let a = Zaehlwerk(roh(gezeigt: 100), stelle: 10, laeuft: true, jetzt: start)!
        // Von 10 s auf 600 s: die Zaehler laufen weiter, die Stelle springt.
        let b = Zaehlwerk(roh(gezeigt: 220), stelle: 600, laeuft: true, vorher: a,
                          jetzt: start.addingTimeInterval(5))!
        #expect(b.laufAnteil == nil)
        #expect(b.basisStelle == 600)
    }

    @Test("Im Stillstand faengt das Fenster von vorn an")
    func pauseZaehltNicht() {
        // Der Anlauf gehoerte einmal mit hinein: `Lauf` stand das ganze Intro
        // lang bei 70 Prozent, ohne dass etwas stockte.
        let start = Date()
        let a = Zaehlwerk(roh(gezeigt: 0), stelle: 0, laeuft: false, jetzt: start)!
        let b = Zaehlwerk(roh(gezeigt: 0), stelle: 0, laeuft: false, vorher: a,
                          jetzt: start.addingTimeInterval(25))!
        #expect(b.laufAnteil == nil)
        #expect(b.basisZeit == b.gemessenAm)
    }

    @Test("Der Vorrat ist gelesen minus entpackt")
    func vorrat() {
        let w = Zaehlwerk(roh(gelesen: 18_000_000, entpackt: 2_000_000),
                          stelle: 5, laeuft: true)!
        #expect(w.vorratBytes == 16_000_000)
        // 16 MiB bei 100 kB/s sind 160 Sekunden.
        #expect(abs((w.vorratSekunden(bytesJeSekunde: 100_000) ?? 0) - 160) < 0.001)
        #expect(w.vorratSekunden(bytesJeSekunde: 0) == nil)
    }

    @Test("Beim ersten Mal steht kein Strich fuer eine Null")
    func ersteMessungOhneRate() {
        let w = Zaehlwerk(roh(gelesen: 5000), stelle: 0, laeuft: true)!
        #expect(w.eingang == nil)
        #expect(w.demuxer == nil)
    }

    @Test("Die Eingangsrate rechnet aus zwei Summen")
    func eingangsrate() {
        let start = Date()
        let a = Zaehlwerk(roh(gelesen: 0), stelle: 0, laeuft: true, jetzt: start)!
        let b = Zaehlwerk(roh(gelesen: 125_000), stelle: 1, laeuft: true, vorher: a,
                          jetzt: start.addingTimeInterval(1))!
        // 125 000 Byte in einer Sekunde sind eine Million Bit.
        #expect(abs((b.eingang ?? 0) - 1_000_000) < 1)
    }
}
