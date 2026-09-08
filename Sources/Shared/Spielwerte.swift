import JellyfinKit
import SwiftUI
#if canImport(VLCKit)
import VLCKit
#endif

/// **Die Bruecke von VLCKit zum Zaehlwerk im Paket — mehr nicht.**
///
/// Die Rechnung selbst liegt seit dem 08.09.2026 in ``JellyfinKit/Zaehlwerk``.
/// Sie stand vorher hier, also nur auf den Apple-Fassungen; Linux und Windows
/// haetten sie ein zweites Mal gebraucht, und eine kopierte Funktion ist ein
/// Fehler (CLAUDE.md). Was hier bleibt, ist das Ablesen der VLCKit-Struktur
/// und das Formatieren fuer die Anzeige.
///
/// **Warum das ueberhaupt jemand sehen will:** diese App transkodiert nie. Ob
/// das gutgeht, sieht man einer Wiedergabe nicht an — ein Bild, das stockt,
/// und ein Bild, das still Einzelbilder wegwirft, sehen aus drei Metern
/// gleich aus. `verworfen` ist der Unterschied.
struct Spielwerte {
    let werk: Zaehlwerk

    // MARK: Durchgereicht — die Namen, die das Schild kennt

    var verworfen: UInt64    { werk.roh.verworfen }
    var zuSpaet: UInt64      { werk.roh.zuSpaet }
    var gezeigt: UInt64      { werk.roh.gezeigt }
    var tonVerloren: UInt64  { werk.roh.tonVerloren }
    var videoBloecke: UInt64 { werk.roh.videoBloecke }
    var tonBloecke: UInt64   { werk.roh.tonBloecke }
    var tonGespielt: UInt64  { werk.roh.tonGespielt }
    /// **Bloecke, die der Demuxer als kaputt erkannt hat.** Das ist die Zahl
    /// hinter „da waren Bildfehler".
    var beschaedigt: UInt64  { werk.roh.beschaedigt }
    /// **Sprungstellen im Strom.** Zeitstempel, die nicht fortlaufen — genau
    /// das sieht man als Ton, der wegwandert.
    var spruenge: UInt64     { werk.roh.spruenge }
    var gelesen: UInt64      { werk.roh.gelesen }
    var entpackt: UInt64     { werk.roh.entpackt }
    var stelle: Double       { werk.stelle }

    var zeigtProSekunde: Double?     { werk.zeigtProSekunde }
    var dekodiertProSekunde: Double? { werk.dekodiertProSekunde }
    var laufAnteil: Double?          { werk.laufAnteil }
    var gemessenAm: Date             { werk.gemessenAm }

    /// Bitraten als fertiger Text — die Formulierung teilen sich alle
    /// Plattformen ueber ``JellyfinKit/Technikangaben/bitrate(_:)``.
    var eingang: String { Technikangaben.bitrate(werk.eingang) ?? "—" }
    var demuxer: String { Technikangaben.bitrate(werk.demuxer) ?? "—" }

    func vorratSekunden(bytesJeSekunde: Double) -> Double? {
        werk.vorratSekunden(bytesJeSekunde: bytesJeSekunde)
    }

    #if canImport(VLCKit)
    init?(_ roh: VLCMedia.Stats?, stelle: Double, laeuft: Bool, vorher: Spielwerte? = nil) {
        guard let roh else { return nil }
        let werte = Zaehlwerk.Rohwerte(
            gelesen: roh.readBytes, entpackt: roh.demuxReadBytes,
            gezeigt: roh.displayedPictures, verworfen: roh.lostPictures,
            zuSpaet: roh.latePictures, videoBloecke: roh.decodedVideo,
            tonBloecke: roh.decodedAudio, tonGespielt: roh.playedAudioBuffers,
            tonVerloren: roh.lostAudioBuffers, beschaedigt: roh.demuxCorrupted,
            spruenge: roh.demuxDiscontinuity)
        guard let werk = Zaehlwerk(werte, stelle: stelle, laeuft: laeuft,
                                   vorher: vorher?.werk) else { return nil }
        self.werk = werk
    }
    #endif
}
