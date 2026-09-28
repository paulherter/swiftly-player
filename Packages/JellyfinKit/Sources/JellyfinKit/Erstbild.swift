import Foundation

/// **Die Uhr läuft, der Ton spielt — und es kam nie ein Bild.**
///
/// ``Stromwacht/bilderStehen(vorher:jetzt:)`` urteilt nur über einen Strom,
/// der schon Bilder gezeigt hat; bei null gibt sie bewusst `nil` zurück,
/// sonst würde ein Titel ohne Bildspur als toter Strom neu aufgebaut. Genau
/// dadurch blieb der Fall „schwarz mit Ton" ungemeldet und ohne Eingriff.
///
/// Diese Regel schließt die Lücke, und zwar nur dort, wo der Server eine
/// Bildspur nennt: dann *muss* ein Bild kommen. Sie rettet in zwei Stufen
/// und hört danach auf — ein Strom, der auch mit Software-Dekoder schwarz
/// bleibt, wird nicht in Schleife neu geöffnet.
public enum Erstbild {

    /// So viel **Filmzeit** ohne ein einziges gezeigtes Bild, bevor
    /// eingegriffen wird.
    ///
    /// Gezählt wird nur, während die Uhr des Abspielers wirklich weiterläuft;
    /// Puffern, Pause und ein Sprung zählen nicht (siehe ``zuwachs(vorher:jetzt:)``).
    /// Warum vier Sekunden reichen:
    ///
    /// - Der Abspieler läuft mit `--no-drop-late-frames`; jedes dekodierte
    ///   Bild erreicht die Ausgabe, auch ein verspätetes. Null gezeigte Bilder
    ///   heißt also: der Dekoder hat nichts geliefert, oder die Ausgabe ist tot
    ///   — nicht „zu langsam".
    /// - VLC startet die Uhr erst, wenn alle Spuren vorgepuffert sind; ein
    ///   gesunder Strom zeigt sein erstes Bild mit dem Start der Uhr. Sprünge
    ///   landen auf Schlüsselbildern (Matroska-Cues, MP4-Sync-Samples).
    /// - Länger warten kostet den Zuschauer Film ohne Bild; ein Fehlgriff
    ///   kostet einen Neuaufbau von rund einer Sekunde. Die Schwelle liegt
    ///   deshalb unter ``Stromwacht/stillstandNormal`` (6 s), aber auf
    ///   ``Stromwacht/pufferruhe`` (4 s).
    public static let frist: TimeInterval = 4

    /// Größter Uhrschritt, der als Laufzeit zählt — der Takt fragt einmal je
    /// Sekunde. Ein größerer Schritt ist ein Sprung, kein Abspielen.
    public static let groessterSchritt: TimeInterval = 2

    /// Was schon versucht wurde. Gilt für einen Titel, nicht für einen Aufbau.
    public enum Stufe: Int, Sendable, Equatable {
        /// Noch nichts.
        case keine = 0
        /// Strom samt Ausgabe an derselben Stelle neu geöffnet.
        case ausgabeNeu = 1
        /// Mit Software-Dekoder neu geöffnet.
        case software = 2
        /// Auch das blieb schwarz. Ab hier Ruhe.
        case aufgegeben = 3
    }

    /// Was die Regel rät.
    public enum Rat: Sendable, Equatable {
        /// Kein Fall: Bild da, keine Bildspur, ausgenommen, oder schon aufgegeben.
        case nichts
        /// Noch keine ``frist`` Filmzeit ohne Bild.
        case warten
        /// Erste Rettung: Strom und Ausgabe an derselben Stelle neu aufbauen.
        case ausgabeNeu
        /// Zweite Rettung: mit Software-Dekoder neu öffnen.
        case softwareDekoder
        /// Beides blieb schwarz: mitschreiben, Hinweis zeigen, nichts mehr tun.
        case aufgeben
    }

    /// - Parameters:
    ///   - hatVideospur: Ob der Server für diesen Titel eine Bildspur nennt.
    ///     Reine Tondateien haben keine und bleiben außen vor.
    ///   - ausgenommen: Bild-im-Bild, AirPlay, Pause — dort ist ein fehlendes
    ///     Bild nicht Sache dieser Regel.
    ///   - gezeigt: Gezeigte Bilder seit dem letzten Aufbau.
    ///   - laufzeit: Filmzeit seit dem letzten Aufbau, in der die Uhr lief.
    ///   - bisher: Was für diesen Titel schon versucht wurde.
    public static func rat(hatVideospur: Bool, ausgenommen: Bool,
                           gezeigt: UInt64, laufzeit: TimeInterval,
                           bisher: Stufe) -> Rat {
        guard hatVideospur, !ausgenommen, gezeigt == 0 else { return .nichts }
        guard bisher != .aufgegeben else { return .nichts }
        guard laufzeit >= frist else { return .warten }
        switch bisher {
        case .keine:      return .ausgabeNeu
        case .ausgabeNeu: return .softwareDekoder
        case .software:   return .aufgeben
        case .aufgegeben: return .nichts
        }
    }

    /// Die Stufe, die nach einem Rat gilt.
    public static func naechste(nach rat: Rat, bisher: Stufe) -> Stufe {
        switch rat {
        case .ausgabeNeu:      .ausgabeNeu
        case .softwareDekoder: .software
        case .aufgeben:        .aufgegeben
        case .nichts, .warten: bisher
        }
    }

    /// Wie viel Filmzeit zwischen zwei Blicken wirklich gelaufen ist.
    ///
    /// Null, wenn es noch keinen Vorwert gibt, die Uhr stand oder rückwärts
    /// ging, und bei einem Schritt über ``groessterSchritt`` — das war ein
    /// Sprung. Ohne diese Grenze gälte ein Sprung um zehn Minuten als zehn
    /// Minuten ohne Bild.
    public static func zuwachs(vorher: TimeInterval?, jetzt: TimeInterval) -> TimeInterval {
        guard let vorher else { return 0 }
        let schritt = jetzt - vorher
        guard schritt > 0, schritt <= groessterSchritt else { return 0 }
        return schritt
    }

    /// Die Option, die VLC auf Software-Dekodierung festlegt.
    ///
    /// `codec` gilt in VLC für alle Spurarten (decoder_helpers.c:
    /// `module_need_var(dec, type, "codec")`), deshalb mit `any` dahinter:
    /// avcodec zuerst, und wo es nicht passt — Untertitel, Durchreichen von
    /// Ton —, nimmt VLC wie sonst das beste Modul. VideoToolbox bzw.
    /// MediaCodec fällt damit für das Bild weg, weil avcodec vor ihnen dran ist.
    public static let softwareOption = ":codec=avcodec,any"

    /// **Dasselbe für libVLC 3 auf Linux und Windows.** Dort steckt die
    /// Hardware nicht in einem eigenen Dekodermodul, sondern in avcodec selbst
    /// (VA-API, VDPAU, D3D11VA, DXVA2 über `avcodec-hw`); ``softwareOption``
    /// allein ließe sie also an. Gemessen am 26.09.2026 mit libVLC 3.0.23 und
    /// einer XviD-AVI: ohne `:avcodec-hw=none` „trying format vaapi" und
    /// „vdpau" für `mpeg4`, mit der Option sucht VLC kein Hardwaremodul mehr.
    public static let softwareOptionenDesktop = [softwareOption, ":avcodec-hw=none"]

    /// **MPEG-4 Part 2 (XviD, DivX) von Anfang an in Software.**
    ///
    /// VLC 3 hat XviD an VideoToolbox gar nicht erst übergeben und gleich
    /// avcodec genommen. VLC 4 reicht jedes MPEG-4 Part 2 an VideoToolbox,
    /// und das lehnt Advanced-Simple-Profile-Material Bild für Bild mit
    /// `kVTVideoDecoderBadDataErr` ab. VLC startet die Sitzung darauf
    /// endlos neu (decoder.c zählt nur den Farbraum-Fall mit), statt auf
    /// avcodec zu wechseln: Ton läuft, das Bild steht oder bleibt schwarz.
    ///
    /// Gemessen am 26.09.2026 mit einer XviD-AVI (624×352, B-Frames) im
    /// iOS-Simulator, je 30 s: frei 59 Bilder dekodiert und über 400
    /// Sitzungsneustarts, mit ``softwareOption`` 806 Bilder, 25 je Sekunde,
    /// kein Fehler. Die ``Erstbild``-Rettung kam zu spät oder gar nicht,
    /// weil vereinzelt doch ein Bild durchrutscht.
    ///
    /// Nur, wenn der Strom unverändert ankommt: beim Umwandeln liefert der
    /// Server ein anderes Format.
    public static func softwareVonAnfang(bildcodec: String?, methode: DeliveryMethod) -> Bool {
        guard methode != .transcode, let bildcodec else { return false }
        return bildcodec.lowercased() == "mpeg4"
    }

    /// Der Hinweis fürs Technikschild, oder `nil`, solange nichts zu sagen ist.
    public static func hinweis(_ stufe: Stufe) -> String? {
        switch stufe {
        case .keine:      nil
        case .ausgabeNeu: uebersetzt("Kein Bild vom Dekoder – Wiedergabe neu aufgebaut")
        case .software:   uebersetzt("Kein Bild vom Dekoder – Software-Dekoder aktiv")
        case .aufgegeben: uebersetzt("Kein Bild vom Dekoder – auch Software-Dekoder ohne Bild")
        }
    }
}
