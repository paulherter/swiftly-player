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
    /// Bitraten kommen als Byte pro Sekunde in `Float` — hier gleich als
    /// Text, damit die Umrechnung an einer Stelle steht.
    let eingang: String
    let demuxer: String

    init?(_ roh: VLCMedia.Stats?) {
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
              roh.decodedAudio < grenze, roh.lostAudioBuffers < grenze
        else { return nil }
        verworfen    = roh.lostPictures
        zuSpaet      = roh.latePictures
        gezeigt      = roh.displayedPictures
        tonVerloren  = roh.lostAudioBuffers
        videoBloecke = roh.decodedVideo
        tonBloecke   = roh.decodedAudio
        eingang      = Spielwerte.rate(roh.inputBitrate)
        demuxer      = Spielwerte.rate(roh.demuxBitrate)
    }

    /// VLC misst in Byte je Sekunde. Mal acht sind Bit, und ab einem Mbit
    /// schreibt sich das lesbarer in Mbit/s.
    private static func rate(_ bytesProSekunde: Float) -> String {
        let bit = Double(bytesProSekunde) * 8
        if bit <= 0 { return "—" }
        if bit >= 1_000_000 {
            return String(format: "%.1f Mbit/s", bit / 1_000_000)
        }
        return String(format: "%.0f kbit/s", bit / 1_000)
    }
}
