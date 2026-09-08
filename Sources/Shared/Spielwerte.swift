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
    init?(_ roh: VLCMedia.Stats?, vorher: Spielwerte? = nil,
          sekunden: Double = 0) {
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
