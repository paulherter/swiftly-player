import JellyfinKit
import SwiftUI
#if canImport(VLCKit)
import VLCKit
#endif

// **Von `Sources/tvOS/Wiedergabeblatt.swift` hierher gehoben.** Das Schild
// gibt es seit dem 08.09.2026 auf allen vier Plattformen, und damit gilt die
// Regel: eine kopierte Funktion ist ein Fehler. Die Werte kommen aus VLC und
// sind auf jedem Geraet dieselben; nur wo das Schild sitzt, unterscheidet
// sich.

/// VLCs Zaehlwerk, uebersetzt.
///
/// **Warum das ueberhaupt jemand sehen will:** diese App transkodiert nie.
/// Ob das gutgeht, sieht man einer Wiedergabe nicht an — ein Bild, das
/// stockt, und ein Bild, das still Einzelbilder wegwirft, sehen aus drei
/// Metern gleich aus. `verworfen` ist der Unterschied. Steht dort eine Null,
/// laeuft die Datei wirklich glatt; steigt sie waehrend des Zusehens, ist
/// die Datei zu schwer fuer das Geraet, und zwar unabhaengig davon, was der
/// Server meldet.
///
/// Die Rohwerte sind kumulativ seit Beginn der Wiedergabe, nicht pro
/// Sekunde — deshalb steht hier auch nichts von „pro Sekunde".
struct Spielwerte {
    let verworfen: UInt64
    let zuSpaet: UInt64
    let gezeigt: UInt64
    let tonVerloren: UInt64
    let videoBloecke: UInt64
    let tonBloecke: UInt64
    let tonGespielt: UInt64
    /// **Bloecke, die der Demuxer als kaputt erkannt hat.** Das ist die Zahl
    /// hinter „da waren Bildfehler": kommt sie hoch, ist der Strom
    /// beschaedigt angekommen — am Netz, am Server oder in der Datei selbst.
    let beschaedigt: UInt64
    /// **Sprungstellen im Strom.** Zeitstempel, die nicht fortlaufen. Genau
    /// das sieht man als Ton, der wegwandert.
    let spruenge: UInt64
    /// Bitraten kommen als Byte pro Sekunde in `Float` — hier gleich als
    /// Text, damit die Umrechnung an einer Stelle steht.
    let eingang: String
    let demuxer: String
    /// Die rohen Summen — nur, um beim naechsten Mal die Rate daraus zu
    /// rechnen. Siehe `init`.
    let gelesen: UInt64
    let entpackt: UInt64
    /// **Wie viele Bilder je Sekunde tatsaechlich auf dem Schirm landen.**
    ///
    /// Aus der Differenz der gezeigten Bilder zwischen zwei Messungen. Das
    /// ist die Zahl, die den Player entlastet oder ueberfuehrt: liegt sie auf
    /// der Rate der Datei, kommt jedes Bild puenktlich an, und was man sieht,
    /// entsteht danach — am Takt des Schirms oder in der Datei selbst. Liegt
    /// sie darunter, ohne dass „verworfen" steigt, haengt der Dekoder.
    ///
    /// **Ueber ein langes Fenster, nicht ueber zwei Sekunden.**
    ///
    /// Ueber zwei Sekunden schwankte diese Zahl zwischen 22,8 und 29,4,
    /// waehrend der Schnitt ueber achtundzwanzig Sekunden bei 24,36 lag —
    /// also genau auf der Rate der Datei. VLC fuehrt seinen Zaehler nicht Bild
    /// fuer Bild, sondern schreibt ihn in Schueben fort; ein kurzes Fenster
    /// faengt mal zwei Schuebe und mal keinen. Die Zahl war damit kein
    /// Messwert, sondern ein Zufallsgenerator mit einer Nachkommastelle —
    /// und man glaubt ihr, weil sie so genau aussieht.
    ///
    /// Zwanzig Sekunden sind rund fuenfhundert Bilder. Ein Schub mehr oder
    /// weniger faellt darin nicht mehr auf.
    let zeigtProSekunde: Double?
    /// Der Bezugspunkt des langen Fensters — Zaehlerstand und Zeitpunkt.
    let basisGezeigt: UInt64
    let basisZeit: Date

    /// **Wie schnell die Stelle vorankommt, gemessen an der echten Uhr.**
    ///
    /// Ein Film laeuft in Echtzeit: in einer Sekunde rueckt die Stelle um
    /// eine Sekunde vor. Steht hier weniger als 1, bleibt die Wiedergabe
    /// zurueck — und *das* ist Haengen, unabhaengig davon, wie viele Bilder
    /// dabei gezeichnet wurden.
    ///
    /// Diese Zahl war noetig, weil `gezeigt` allein luegt. Am 08.09.2026
    /// standen auf dem Apple TV 1015 gezeigte Bilder bei Stelle 0:28 — 28
    /// Sekunden Film sind aber nur 671 Bilder. VLC zeichnet ein stehendes
    /// Bild neu, wenn der Strom nicht nachkommt, und zaehlt jede
    /// Wiederholung mit. Ein Zaehler, der beim Haengen *schneller* laeuft,
    /// taugt nicht als Bildrate.
    let laufAnteil: Double?
    /// Die Stelle dieser Messung und die des Fensteranfangs, beide in
    /// Sekunden.
    let stelle: Double
    let basisStelle: Double

    /// **Dekodierte Bilder je Sekunde, ueber dasselbe lange Fenster.**
    ///
    /// Die Zahl, die Dekoder und Ausgabe trennt. Der Vorrat kann randvoll
    /// sein und die Stelle trotzdem zurueckbleiben -- dann liegt der Engpass
    /// hinter dem Demuxer, und es gibt genau zwei Stellen dafuer. Steht hier
    /// die Bildrate der Datei, kommt der Dekoder mit, und es klemmt bei der
    /// Ausgabe. Steht hier weniger, ist der Dekoder zu langsam; bei HEVC auf
    /// diesen Geraeten heisst das fast immer, dass nicht VideoToolbox
    /// rechnet, sondern die CPU.
    let dekodiertProSekunde: Double?
    let basisDekodiert: UInt64

    /// **Die Rate wird selbst gerechnet, nicht abgelesen.**
    ///
    /// `inputBitrate` und `demuxBitrate` sind Fliesskommafelder, die VLC
    /// selbst fuehrt — und auf dem Apple TV standen sie bei laufendem Film
    /// beide auf **0**, am Geraet nachgesehen. Was verlaesslich steigt, sind
    /// die Summen `readBytes` und `demuxReadBytes`. Aus zwei Messungen und
    /// der Zeit dazwischen wird daraus eine Rate, die stimmt, weil sie auf
    /// nichts angewiesen ist als auf zwei Zahlen, die nur wachsen koennen.
    ///
    /// Beim ersten Mal gibt es kein Vorher — dann steht ein Strich, keine
    /// Null. Eine Null waere eine Aussage, und wir haben noch keine.
    /// Wann diese Messung entstanden ist — die naechste rechnet daraus die
    /// Dauer. **Gemessen, nicht angenommen:** `Task.sleep` haelt
    /// *mindestens* die gewuenschte Zeit ein, nicht genau sie. Mit einer
    /// angenommenen Dauer las man am 08.09.2026 „Zeigt 30,0 fps" bei einer
    /// Datei mit 23,976 — der Abstand war in Wahrheit zweieinhalb Sekunden.
    /// Eine Auskunft, die falsche Zahlen mit zwei Nachkommastellen ausgibt,
    /// ist schlimmer als keine.
    let gemessenAm: Date

    init?(_ roh: VLCMedia.Stats?, stelle: Double, laeuft: Bool, vorher: Spielwerte? = nil) {
        let jetzt = Date()
        self.stelle = stelle
        let sekunden = vorher.map { jetzt.timeIntervalSince($0.gemessenAm) } ?? 0
        gemessenAm = jetzt
        guard let roh else { return nil }
        // **Hat VLC die Struktur gar nicht gefuellt, kommt Speicherschrott.**
        //
        // `statistics` liefert sie auch dann, wenn das Medium noch keine hat;
        // die Felder stehen dann auf dem, was zufaellig im Speicher lag. Eine
        // Milliarde Bilder waeren bei 60 Hz ueber ein halbes Jahr am Stueck —
        // was darueber liegt, ist keine Messung.
        let grenze: UInt64 = 1_000_000_000
        guard roh.displayedPictures < grenze, roh.lostPictures < grenze,
              roh.latePictures < grenze, roh.decodedVideo < grenze,
              roh.decodedAudio < grenze, roh.lostAudioBuffers < grenze,
              roh.demuxCorrupted < grenze, roh.demuxDiscontinuity < grenze,
              roh.playedAudioBuffers < grenze
        else { return nil }
        verworfen    = roh.lostPictures
        zuSpaet      = roh.latePictures
        gezeigt      = roh.displayedPictures
        tonVerloren  = roh.lostAudioBuffers
        videoBloecke = roh.decodedVideo
        tonBloecke   = roh.decodedAudio
        tonGespielt  = roh.playedAudioBuffers
        beschaedigt  = roh.demuxCorrupted
        spruenge     = roh.demuxDiscontinuity
        gelesen      = roh.readBytes
        entpackt     = roh.demuxReadBytes
        // Der Bezugspunkt bleibt zwanzig Sekunden stehen und wird dann
        // nachgezogen. Springt der Zaehler zurueck — Sprung, Folgenwechsel —,
        // faengt das Fenster von vorn an.
        let fenster: TimeInterval = 20
        // **Ein Sprung macht das Fenster ungueltig.** Die Zaehler laufen
        // dabei weiter, die Stelle aber springt — ohne diese Pruefung waere
        // `laufAnteil` nach jedem Vorspulen minutenlang Unsinn. Plausibel
        // ist eine Stelle, die vorwaerts geht und dabei hoechstens doppelt
        // so schnell wie die Uhr.
        //
        // **Und der Anlauf gehoert nicht dazu.** Das Fenster begann bisher
        // bei der ersten Messung, und die liegt vor dem ersten Bild: die
        // Zeit, in der VLC seinen Vorrat fuellt, floss als Stillstand in die
        // Rechnung ein. Mit zehn Sekunden Vorlauf stand `Lauf` dadurch das
        // ganze Intro lang bei 70 Prozent, ohne dass irgendetwas stockte.
        // Solange nicht laeuft -- Anlauf, Pause, Sprung --, faengt das
        // Fenster deshalb immer wieder von vorn an. Ein Stocken *waehrend*
        // der Wiedergabe bleibt sichtbar: dort steht `laeuft` auf wahr und
        // die Stelle bleibt trotzdem zurueck, und genau das ist die Frage.
        let stelleLaeuftFort = laeuft && (vorher.map {
            stelle >= $0.stelle && stelle - $0.stelle <= sekunden * 2 + 1
        } ?? false)
        if let vorher, stelleLaeuftFort, roh.displayedPictures >= vorher.basisGezeigt,
           jetzt.timeIntervalSince(vorher.basisZeit) < fenster {
            basisGezeigt = vorher.basisGezeigt
            basisZeit = vorher.basisZeit
            basisStelle = vorher.basisStelle
            basisDekodiert = vorher.basisDekodiert
        } else if let vorher, stelleLaeuftFort, roh.displayedPictures >= vorher.gezeigt {
            basisGezeigt = vorher.gezeigt
            basisZeit = vorher.gemessenAm
            basisStelle = vorher.stelle
            basisDekodiert = vorher.videoBloecke
        } else {
            basisGezeigt = roh.displayedPictures
            basisZeit = jetzt
            basisStelle = stelle
            basisDekodiert = roh.decodedVideo
        }
        let spanne = jetzt.timeIntervalSince(basisZeit)
        if spanne >= 4, roh.displayedPictures >= basisGezeigt {
            zeigtProSekunde = Double(roh.displayedPictures - basisGezeigt) / spanne
        } else {
            zeigtProSekunde = nil
        }
        if spanne >= 4, stelle >= basisStelle {
            laufAnteil = (stelle - basisStelle) / spanne
        } else {
            laufAnteil = nil
        }
        if spanne >= 4, roh.decodedVideo >= basisDekodiert {
            dekodiertProSekunde = Double(roh.decodedVideo - basisDekodiert) / spanne
        } else {
            dekodiertProSekunde = nil
        }
        eingang      = Spielwerte.rate(roh.readBytes, vorher?.gelesen, sekunden)
        demuxer      = Spielwerte.rate(roh.demuxReadBytes, vorher?.entpackt, sekunden)
    }

    /// Aus zwei Summen und der Zeit dazwischen eine Rate.
    ///
    /// Ohne Vorher gibt es keine Rate — dann steht ein Strich. Und wenn die
    /// Summe kleiner geworden ist, hat VLC das Medium neu aufgesetzt (Sprung,
    /// Folgenwechsel); auch dann ist die Differenz keine Messung.
    private static func rate(_ jetzt: UInt64, _ vorher: UInt64?,
                             _ sekunden: Double) -> String {
        guard let vorher, sekunden > 0, jetzt >= vorher else { return "—" }
        let bit = Double(jetzt - vorher) * 8 / sekunden
        if bit <= 0 { return "—" }
        if bit >= 1_000_000 {
            return String(format: "%.1f Mbit/s", bit / 1_000_000)
        }
        return String(format: "%.0f kbit/s", bit / 1_000)
    }
}
