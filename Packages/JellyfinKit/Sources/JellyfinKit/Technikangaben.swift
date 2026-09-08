import Foundation

/// Was im Technikschild steht — die Regeln, nicht die Darstellung.
///
/// **Warum das hier liegt und nicht in der Ansicht.** Vier Plattformen zeigen
/// dasselbe Schild, und jede haette sonst ihre eigene Fassung von „wie
/// schreibt man hevc" und „ab wann sind es Mbit/s". Genau daran sind
/// `nachladen()`, `trefferauskunft` und `Spielzeit` schon einmal
/// auseinandergelaufen. Hier steht es einmal und ist ohne Simulator
/// nachzurechnen.
public enum Technikangaben {

    // MARK: Codecnamen

    /// Wie ein Codec geschrieben wird, wenn ein Mensch ihn liest.
    ///
    /// Der Server gibt Kleinbuchstaben aus dem Container heraus — `hevc`,
    /// `eac3`, `hdmv_pgs_subtitle`. Das ist die Schreibweise des Containers,
    /// nicht die des Menschen; auf einem Schild, das beim Fehlersuchen hilft,
    /// soll stehen, was in der Fehlermeldung auch stehen wuerde.
    public static func codecname(_ roh: String?) -> String? {
        guard let roh, !roh.isEmpty else { return nil }
        switch roh.lowercased() {
        case "h264", "avc":               return "H.264"
        case "hevc", "h265":              return "HEVC"
        case "av1":                       return "AV1"
        case "vp9":                       return "VP9"
        case "mpeg2video":                return "MPEG-2"
        case "vc1":                       return "VC-1"
        case "aac", "aac_latm":           return "AAC"
        case "ac3":                       return "AC-3"
        case "eac3":                      return "E-AC-3"
        case "dts", "dca":                return "DTS"
        case "dtshd":                     return "DTS-HD"
        case "truehd":                    return "TrueHD"
        case "mlp":                       return "MLP"
        case "flac":                      return "FLAC"
        case "alac":                      return "ALAC"
        case "opus":                      return "Opus"
        case "mp3":                       return "MP3"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub":    return "VobSub"
        case "subrip", "srt":             return "SRT"
        case "ass", "ssa":                return "ASS"
        case "mov_text":                  return "MOV-Text"
        default:                          return roh.uppercased()
        }
    }

    /// Wie viele Kanaele, in der Schreibweise, die jeder kennt.
    ///
    /// 6 heisst 5.1 und 8 heisst 7.1 — die Zahl der Kanaele ist nicht die
    /// Zahl, die auf der Huelle steht.
    public static func kanalwort(_ anzahl: Int?) -> String? {
        switch anzahl {
        case .some(1): "Mono"
        case .some(2): "Stereo"
        case .some(6): "5.1"
        case .some(8): "7.1"
        case .some(let n) where n > 0: "\(n) ch"
        default: nil
        }
    }

    // MARK: Zahlen

    /// Bit pro Sekunde als Text. Ab einem Megabit in Mbit/s, darunter in
    /// kbit/s — darunter wird die Nachkommastelle zur Beliebigkeit.
    public static func bitrate(_ bitProSekunde: Double?) -> String? {
        guard let b = bitProSekunde, b > 0 else { return nil }
        if b >= 1_000_000 {
            return String(format: "%.1f Mbit/s", b / 1_000_000)
        }
        return String(format: "%.0f kbit/s", b / 1_000)
    }

    /// Bildrate mit hoechstens drei Nachkommastellen, aber ohne die Nullen,
    /// die niemand liest: 23,976 bleibt, 59,94 bleibt 59,94 und wird nicht zu
    /// 59,940, und 25,000 wird 25.
    ///
    /// Die Nullen wegzulassen ist kein Feinschliff: das Schild steht ueber
    /// dem Bild und hat wenig Platz, und eine Stelle, die immer null ist,
    /// traegt nichts.
    public static func bildrate(_ wert: Double?) -> String? {
        guard let w = wert, w > 0 else { return nil }
        var text = String(format: "%.3f", (w * 1000).rounded() / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Aufloesung plus Farbtiefe und Umfang, soweit bekannt.
    public static func bildzeile(breite: Int?, hoehe: Int?,
                                 tiefe: Int?, umfang: String?) -> String? {
        guard let breite, let hoehe, breite > 0, hoehe > 0 else { return nil }
        var text = "\(breite)×\(hoehe)"
        if let tiefe, tiefe > 0 { text += " · \(tiefe) bit" }
        if let umfang, !umfang.isEmpty, umfang.uppercased() != "SDR" {
            text += " · \(umfang.uppercased())"
        }
        return text
    }

    // MARK: Auslieferung

    /// Wie schwer die Auslieferungsart wiegt — daran haengt die Farbe.
    ///
    /// Direct Play und Direct Stream sind beide verlustfrei und stehen
    /// deshalb gleich da. Nur die Umrechnung ist die Ausnahme, die diese App
    /// zu vermeiden verspricht, und nur sie faellt farblich auf.
    public enum Gewicht: Sendable, Equatable { case gut, warnend }

    public static func gewicht(_ art: DeliveryMethod) -> Gewicht {
        art.isLossless ? .gut : .warnend
    }

    /// Das Wort auf dem Schild.
    public static func auslieferung(_ art: DeliveryMethod) -> String {
        switch art {
        case .directPlay:   uebersetzt("Direct Play")
        case .directStream: uebersetzt("Direct Stream")
        case .transcode:    uebersetzt("Transkodiert")
        }
    }
}
