import AVKit
import CoreMedia
import OSLog
import UIKit
import JellyfinKit
import VLCKit

/// **Sagt dem Fernseher, mit welcher Bildrate der Film läuft.**
///
/// Das war die Ursache dafür, dass sich die Wiedergabe stockend anfühlte,
/// obwohl nichts fehlte. Pauls Messung: 4 zu späte Bilder auf 4888, und die
/// vier stammten vom Spulen. Es wurde also nichts verworfen und nichts
/// verpasst — die Bilder kamen nur ungleichmäßig auf den Schirm.
///
/// **Warum.** Ein Film liegt in 23,976 oder 24 Bildern je Sekunde vor, der
/// Apple TV gibt aber 60 Hz aus. 24 geht in 60 nicht auf, also wird jedes
/// zweite Bild dreimal und jedes andere zweimal gezeigt — 3:2-Pulldown. Die
/// Bewegung läuft dadurch abwechselnd zu schnell und zu langsam. Bei
/// Schwenks sieht man es sofort, bei ruhigen Bildern gar nicht, und kein
/// Zähler meldet etwas, weil kein Bild verlorengeht.
///
/// **Warum es auf dem iPhone nicht auffiel.** Paul: „aufm iPhone fühlt sich
/// dasselbe halt flüssig an." Sein iPhone hat ProMotion und läuft mit 120 Hz.
/// 24 geht in 120 glatt fünfmal auf — jedes Bild steht gleich lang. Dieselbe
/// Datei, derselbe Abspieler, dieselbe Leitung: allein die Ausgabe entscheidet.
///
/// **Warum es bei Netflix nicht auffiel.** Die setzen dasselbe, was hier
/// jetzt steht. `AVDisplayManager.preferredDisplayCriteria` bittet tvOS, den
/// Ausgang auf die Bildrate des Inhalts umzustellen — 24p ins Bild bei 24 Hz.
///
/// **Es hängt an einer Einstellung des Geräts.** Ohne „Einstellungen → Video
/// und Audio → Inhalt anpassen → Bildrate anpassen" bleibt der Wunsch
/// unbeachtet; `erlaubt` sagt, ob er ankommt. Das ist keine Schwäche unserer
/// Fassung — auch Netflix judert dann.
@MainActor
enum Bildtakt {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "Bildtakt")

    /// Was zuletzt gesetzt wurde. Dieselbe Rate noch einmal zu setzen löst
    /// einen zweiten Moduswechsel aus — und bei jedem wird der Schirm für
    /// ein paar Sekunden schwarz.
    private static var zuletzt: Float?

    /// **Das Schlüsselfenster, nicht irgendeines.**
    ///
    /// `windows.first` ist die Reihenfolge, in der sie angelegt wurden, nicht
    /// die, in der sie auf dem Schirm liegen. Trifft es ein Fenster, das
    /// keinem Bildschirm zugeordnet ist, kommt kein Verwalter heraus — und
    /// dann sähe es genauso aus, als hätte der Nutzer die Anpassung
    /// abgeschaltet. Zwei sehr verschiedene Ursachen mit derselben Anzeige.
    private static var fenster: UIWindow? {
        let alle = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return alle.first(where: \.isKeyWindow) ?? alle.first
    }

    private static var verwalter: AVDisplayManager? { fenster?.avDisplayManager }

    /// Woran es liegt, wenn nichts umgeschaltet wird.
    enum Stand {
        /// Der Fernseher schaltet mit.
        case bereit
        /// „Bildrate anpassen" ist in den Geräteeinstellungen aus.
        case abgeschaltet
        /// Kein Anzeigeverwalter erreichbar — dann liegt es an uns, nicht am
        /// Gerät.
        case unerreichbar
    }

    static var stand: Stand {
        guard let verwalter else { return .unerreichbar }
        return verwalter.isDisplayCriteriaMatchingEnabled ? .bereit : .abgeschaltet
    }

    /// Die Rate, auf die wir den Ausgang gestellt haben — `nil`, wenn nicht
    /// geschaltet wurde.
    static var angefordert: Double? { zuletzt.map(Double.init) }

    /// Ob das Gerät Moduswechsel überhaupt zulässt.
    static var erlaubt: Bool { stand == .bereit }

    /// Wann der laufende Wechsel angestossen wurde.
    private static var wechselSeit: Date?

    /// **Die einmal gemessene Rate — und der Grund, warum sie gemerkt wird.**
    ///
    /// `rate(von:)` fragt `media.videoTracks`. Das ist keine Ablesung eines
    /// Feldes: VLCKit baut die Spurliste bei jedem Zugriff neu auf. Im
    /// halben Sekundentakt aufgerufen — und genau so stand es im
    /// Wiedergabetakt — greift das dauernd in ein Medium, das gerade
    /// abspielt. Paul: „jetzt laedt ueberhaupt nichts mehr", dazu
    /// Statistikwerte in Trilliardenhoehe, also eine Struktur, die VLC gar
    /// nicht gefuellt hat.
    ///
    /// Die Bildrate einer Datei aendert sich nicht. Einmal lesen genuegt.
    private static var gemessen: Double?
    /// Damit ein Medium ohne lesbare Spuren nicht ewig weiter befragt wird.
    private static var versuche = 0

    /// Während des Wechsels ist das Bild schwarz — der Ladeschirm muss stehen
    /// bleiben, sonst sieht es aus, als sei die Wiedergabe abgestürzt.
    ///
    /// **Mit Frist.** Apple schreibt selbst, die Angabe haenge an der Hardware
    /// und der Wechsel koenne laenger dauern, als sie meldet — dann taugt sie
    /// auch andersherum nicht. Bliebe sie haengen, haelt sie den Ladeschirm
    /// fuer immer, und aus einem kurzen Schwarzbild wuerde ein Film, der nie
    /// anfaengt. Ein sichtbares Aufblitzen ist der bessere Fehler.
    static var schaltetUm: Bool {
        guard verwalter?.isDisplayModeSwitchInProgress == true else { return false }
        guard let wechselSeit else { return false }
        return Date().timeIntervalSince(wechselSeit) < 8
    }

    /// Die Bildrate der laufenden Datei übernehmen.
    ///
    /// Gibt die erkannte Rate zurück, wenn etwas gesetzt wurde — sonst `nil`.
    /// VLC kennt die Spuren, sobald der Strom offen ist, und das ist deutlich
    /// vor dem ersten Bild: der Wechsel läuft dadurch hinter dem Ladeschirm ab
    /// und ist nicht zu sehen.
    /// Die Bildrate der laufenden Datei, sobald VLC die Spuren kennt.
    ///
    /// Auch fuer die Technikauskunft: dort ist sie die Zeile, die „es ruckelt,
    /// aber nichts fehlt" erklaert.
    static func rate(von spieler: VLCMediaPlayer) -> Double? {
        if let gemessen { return gemessen }
        guard versuche < 40 else { return nil }
        versuche += 1
        guard let bild = spieler.media?.videoTracks.first?.video,
              bild.frameRateDenominator > 0
        else { return nil }
        let rate = Double(bild.frameRate) / Double(bild.frameRateDenominator)
        // Unsinnige Werte kommen vor, solange der Strom sich noch sortiert.
        guard rate > 1, rate < 250 else { return nil }
        gemessen = rate
        return rate
    }

    /// Ob noch etwas nachzumessen ist. Ist nichts mehr offen, darf der Takt
    /// das Medium in Ruhe lassen.
    static var nochNachzumessen: Bool { gemessen == nil && versuche < 40 }

    /// Aus den Angaben des Servers — **vor** dem Öffnen des Stroms.
    ///
    /// **Warum so früh.** Der Wechsel kostet den Fernseher ein paar Sekunden
    /// Schwarzbild. Läuft er erst, wenn VLC die Spuren kennt, ragt er hinten
    /// aus dem Ladeschirm heraus und man sieht ihn. Hier startet er im selben
    /// Moment wie der Aufbau des Stroms, und beide brauchen ähnlich lang —
    /// dann liegt das Schwarzbild in der Zeit, in der ohnehin nichts zu sehen
    /// ist. Was der Server nicht sagt, holt `anpassen(an:)` später nach.
    @discardableResult
    static func anpassen(laut angabe: MediaStream?) -> Double? {
        // **Ins Dateiprotokoll, nicht nur ins Systemprotokoll.**
        //
        // Am Fernseher kommt an Apples Log niemand heran; dieselbe Falle wie
        // bei VLCs eigenen Zeilen. Und es ist die Zahl, mit der sich Ruckeln
        // ohne verworfene Bilder ueberhaupt erst erklaeren laesst: schaltet
        // der Ausgang nicht um, laufen 23,976 Bilder auf 60 Hz, und das
        // ruckelt sichtbar, obwohl kein einziges Bild fehlt.
        Protokoll.schreib("[Takt] Server sagt: real=\(angabe?.realFrameRate.map { String(format: "%.3f", $0) } ?? "—")"
            + " mittel=\(angabe?.averageFrameRate.map { String(format: "%.3f", $0) } ?? "—")"
            + " → benutzbar=\(angabe?.bildrate.map { String(format: "%.3f", $0) } ?? "nein")")
        guard let angabe, let rate = angabe.bildrate else { return nil }
        return setzen(rate: rate,
                      breite: Int32(angabe.width ?? 1920),
                      hoehe: Int32(angabe.height ?? 1080),
                      codec: kennung(text: angabe.codec),
                      umfang: Farbauskunft.umfang(typ: angabe.videoRangeType,
                                                  kennlinie: angabe.colorTransfer,
                                                  primaervalenzen: angabe.colorPrimaries))
    }

    @discardableResult
    static func anpassen(an spieler: VLCMediaPlayer) -> Double? {
        guard nochNachzumessen, let rate = rate(von: spieler) else { return nil }
        guard let spur = spieler.media?.videoTracks.first, let bild = spur.video
        else { return nil }
        // VLC gibt den Farbumfang nicht heraus — hier bleibt es beim
        // Nachmessen der Bildrate. Den Umfang hat der Server schon vorher
        // gesetzt, falls er ihn kannte.
        return setzen(rate: rate,
                      breite: Int32(bild.width),
                      hoehe: Int32(bild.height),
                      codec: kennung(spur.codec),
                      umfang: .unbekannt)
    }

    private static func setzen(rate: Double, breite: Int32, hoehe: Int32,
                               codec: CMVideoCodecType,
                               umfang: Farbumfang) -> Double? {
        // **Nicht umschalten, wenn es nichts bringt.**
        //
        // Jeder Wechsel kostet ein paar Sekunden Schwarzbild — der Grund,
        // aus dem Paul die Anpassung ueberhaupt abgeschaltet hatte. Geht die
        // Bildrate im laufenden Modus glatt auf, steht jedes Bild schon jetzt
        // gleich lang und der Wechsel waere reiner Verlust: 30 in 60 ist
        // zweimal, 60 in 60 einmal. Krumm sind 24, 23,976, 25, 48 und 50 —
        // und genau die judern.
        if passt(rate) {
            log.info("\(rate, privacy: .public) fps geht im laufenden Modus auf — kein Wechsel")
            return rate
        }

        guard erlaubt else {
            log.info("Bildratenanpassung ist am Gerät abgeschaltet — \(rate, privacy: .public) fps bleibt ungenutzt")
            return nil
        }

        // **Mit Toleranz vergleichen, nicht auf die Stelle genau.**
        //
        // Der Server nennt 23,976023976…, VLC rechnet aus Zaehler und Nenner
        // einen minimal anderen Wert. Auf Gleichheit geprueft waere das ein
        // zweiter Moduswechsel fuer nichts — und jeder kostet drei Sekunden
        // Schwarzbild. Ein Zwanzigstel Bild Unterschied ist keiner.
        let gewuenscht = Float(rate)
        if let zuletzt, abs(zuletzt - gewuenscht) < 0.05 { return rate }

        // **Mit Farbangaben, wenn der Server welche nennt.**
        //
        // Hier stand einmal „welchen Umfang die Datei hat, weiß hier
        // niemand" — das stimmte, solange `VideoRangeType` nicht im Modell
        // war. Seit dem 03.09.2026 ist es das, und damit kann die
        // Beschreibung die Kennlinie tragen und tvOS den HDMI-Ausgang
        // umstellen.
        //
        // **Die Regel von damals gilt unverändert weiter:** sagt der Server
        // nichts, wird nichts gesetzt. Ein HDR-Film in SDR sieht ausgewaschen
        // aus, ein SDR-Film in HDR flau — geraten ist schlimmer als gelassen.
        //
        // **Was das nicht kann: Dolby Vision.** Ein Ausgang, der über eine
        // Formatbeschreibung angefordert wird, geht nach HDR10, nicht nach
        // DV. Ein DV-Film landet also in HDR10 — richtig in Kennlinie und
        // Primärvalenzen, ohne die dynamischen Metadaten. Besser als SDR,
        // aber nicht dasselbe.
        var beschreibung: CMVideoFormatDescription?
        var farben: CFDictionary?
        if let kennlinie = umfang.kennlinie {
            farben = [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
                kCVImageBufferTransferFunctionKey: kennlinie == .pq
                    ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                    : kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            ] as CFDictionary
        }

        let ergebnis = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: breite,
            height: hoehe,
            extensions: farben,
            formatDescriptionOut: &beschreibung)

        guard ergebnis == noErr, let beschreibung else {
            log.error("Formatbeschreibung fehlgeschlagen: \(ergebnis, privacy: .public)")
            return nil
        }

        verwalter?.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: gewuenscht,
                                                                formatDescription: beschreibung)
        zuletzt = gewuenscht
        wechselSeit = Date()
        log.info("Ausgang auf \(rate, privacy: .public) Hz gestellt (\(breite, privacy: .public)×\(hoehe, privacy: .public))")
        Protokoll.schreib("[Takt] Ausgang auf \(String(format: "%.3f", rate)) Hz gestellt"
            + " (\(breite)×\(hoehe), \(umfang.rawValue)"
            + "\(umfang.kennlinie.map { $0 == .pq ? ", PQ" : ", HLG" } ?? ", ohne Farbangaben"))")
        return rate
    }

    /// Zurück auf den Modus für die Oberfläche. Nur, wenn wir wirklich etwas
    /// gesetzt haben — sonst löst das Aufräumen selbst einen Wechsel aus.
    static func loesen() {
        // **Die Messung wird immer zurueckgesetzt, der Ausgang nur wenn
        // noetig.** Vorher hing beides an derselben Bedingung, und die traf
        // genau dann nicht zu, wenn gar nicht umgeschaltet wurde. Wer eine
        // Serie sah, deren Bildrate schon aufging, nahm deren Wert mit in den
        // naechsten Titel — und fuer den wurde dann nicht mehr geschaltet,
        // obwohl er es gebraucht haette. Zwei Dinge, eine Bedingung.
        gemessen = nil
        versuche = 0

        guard zuletzt != nil else { return }
        verwalter?.preferredDisplayCriteria = nil
        zuletzt = nil
        wechselSeit = nil
        log.info("Ausgang wieder freigegeben")
    }

    /// Womit der Ausgang gerade läuft.
    ///
    /// Die einzige Zahl, die wirklich sagt, ob der Fernseher umgeschaltet
    /// hat. Alles andere ist Absicht.
    /// Vom selben Fenster wie der Verwalter — nicht von `UIScreen.main`.
    /// Zwei Auskünfte über dieselbe Anzeige sollten dieselbe Quelle haben.
    static var schirmtakt: Int {
        fenster?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
    }

    /// Ob die Bildrate im gerade laufenden Anzeigemodus glatt aufgeht.
    ///
    /// `maximumFramesPerSecond` ist auf dem Fernseher die Rate, mit der der
    /// Ausgang wirklich laeuft — nicht eine Obergrenze wie am Telefon.
    private static func passt(_ rate: Double) -> Bool {
        let takt = Double(schirmtakt)
        guard takt > 1 else { return false }
        let faktor = takt / rate
        // 23,976 ist nicht 24: eine knappe Toleranz, sonst faellt der
        // haeufigste Kinowert durchs Raster und wir schalten grundlos.
        return abs(faktor - faktor.rounded()) < 0.01
    }

    /// VLCs Vierzeichenkennung in die von CoreMedia.
    ///
    /// Für die Wahl des Anzeigemodus zählt die Bildrate; die Kennung muss nur
    /// plausibel sein. Unbekanntes geht als HEVC durch — das ist bei Direct
    /// Play der häufigste Fall.
    /// Dasselbe aus Jellyfins Codecnamen — der Server schickt Text, nicht
    /// eine Vierzeichenkennung.
    private static func kennung(text: String?) -> CMVideoCodecType {
        switch text?.lowercased() {
        case "h264", "avc", "avc1": return kCMVideoCodecType_H264
        case "mpeg4", "msmpeg4v3":  return kCMVideoCodecType_MPEG4Video
        case "vp9":                 return kCMVideoCodecType_VP9
        case "av1":                 return kCMVideoCodecType_AV1
        default:                    return kCMVideoCodecType_HEVC
        }
    }

    private static func kennung(_ fourcc: UInt32) -> CMVideoCodecType {
        let zeichen = String(bytes: [UInt8((fourcc >> 24) & 0xFF),
                                     UInt8((fourcc >> 16) & 0xFF),
                                     UInt8((fourcc >> 8) & 0xFF),
                                     UInt8(fourcc & 0xFF)],
                             encoding: .ascii)?.lowercased() ?? ""
        switch zeichen {
        case "h264", "avc1", "x264": return kCMVideoCodecType_H264
        case "mp4v", "divx", "xvid": return kCMVideoCodecType_MPEG4Video
        case "vp09", "vp90":         return kCMVideoCodecType_VP9
        case "av01":                 return kCMVideoCodecType_AV1
        default:                     return kCMVideoCodecType_HEVC
        }
    }
}
