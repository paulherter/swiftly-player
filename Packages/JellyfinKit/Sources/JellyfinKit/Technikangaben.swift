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

    /// Codecname aus libVLCs Kennung (`i_codec`), etwa `mp4a` → „AAC".
    ///
    /// Die vier Zeichen liegen **niederwertiges Byte zuerst** — am 16.09.2026
    /// an VLCKit auf dem Mac gemessen, `mp4a` kam so heraus. libVLCs eigener
    /// `codecName()` schreibt „MPEG AAC Audio", deshalb diese Tabelle.
    public static func codecname(vlcKennung kennung: UInt32) -> String? {
        let bytes = [kennung, kennung >> 8, kennung >> 16, kennung >> 24].map { UInt8($0 & 0xFF) }
        guard let zeichen = String(bytes: bytes, encoding: .ascii)?
            .lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        let roh: String? = switch zeichen {
        case "mp4a":         "aac"
        case "a52":          "ac3"
        case "eac3":         "eac3"
        case "dts":          "dts"
        case "trhd":         "truehd"
        case "mlp":          "mlp"
        case "flac":         "flac"
        case "alac":         "alac"
        case "opus":         "opus"
        case "mp3":          "mp3"
        case "vorb":         "vorbis"
        // Untertitel — für die Gegenprobe in ``Spurzuordnung``.
        case "subt":         "subrip"
        case "ssa":          "ass"
        case "bdpg":         "hdmv_pgs_subtitle"
        case "spu":          "dvd_subtitle"
        case "tx3g":         "mov_text"
        default:             nil
        }
        return codecname(roh)
    }

    /// Eine Tonspur in einer Zeile — „Deutsch · AAC · 5.1".
    ///
    /// Für Spuren, die der Spieler selbst meldet. Die Sprache kommt dort je
    /// nach Datei als „ger", „deu" oder „German"; was `Locale` nicht kennt,
    /// löst ``Sprache/erkannt(in:)`` auf.
    public static func tonspurname(sprache roh: String?, codec: String?, kanaele: Int?) -> String? {
        var sprachwort: String?
        if let roh, !roh.isEmpty {
            let gelesen = sprache(roh)
            sprachwort = gelesen != roh ? gelesen : (Sprache.erkannt(in: roh) ?? roh)
        }
        let teile = [sprachwort, codec, kanalwort(kanaele)].compactMap { $0 }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
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

    /// Die Sprache einer Spur, wie ein Mensch sie liest.
    ///
    /// Der Server gibt den ISO-Code heraus, und `und` ist darin nicht die
    /// Konjunktion, sondern „undetermined" — der Wert, den eine Datei traegt,
    /// wenn niemand eine Sprache eingetragen hat. Auf dem Schild stand
    /// dadurch woertlich „Ton AAC · 5.1 · und", und das liest sich wie ein
    /// abgeschnittener Satz.
    public static func sprache(_ roh: String?) -> String? {
        guard let roh, !roh.isEmpty else { return nil }
        let code = roh.lowercased()
        // `mis` heisst „miscellaneous", `zxx` „kein sprachlicher Inhalt".
        if ["und", "unknown", "unbekannt", "mis", "zxx"].contains(code) {
            return uebersetzt("unbekannt")
        }
        return Locale.current.localizedString(forLanguageCode: code) ?? roh
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

    // MARK: Dynamikumfang

    /// **Welche HDR-Art die Datei trägt** — „HDR10", „HDR10+", „HLG", „SDR"
    /// oder „Dolby Vision P8.1 · HDR10" (Profil und, nach dem Punkt, die
    /// Basisschicht, auf die ein Gerät ohne Dolby Vision zurückfällt).
    ///
    /// **Das Format der Datei, nicht der Ausgang.** Ob das Gerät das Signal
    /// als HDR ausgibt oder VLC es auf SDR abbildet, weiß keine Plattform
    /// zuverlässig — deshalb behauptet die Zeile darüber nichts. Sie steht im
    /// oberen Teil des Schildes, der die Datei beschreibt.
    ///
    /// Die Namen sind Formatnamen und werden nicht übersetzt. `nil`, wenn der
    /// Server nichts Brauchbares sagt — geraten wird nicht (``Farbauskunft``).
    public static func dynamik(_ spur: MediaStream?) -> String? {
        guard let spur else { return nil }
        var umfang = Farbauskunft.umfang(typ: spur.videoRangeType,
                                         kennlinie: spur.colorTransfer,
                                         primaervalenzen: spur.colorPrimaries)
        // Ungültige DV-Angaben spielt jeder Player als Basisschicht — dann
        // zählt, was die rohen Angaben über die sagen.
        if umfang == .dolbyVisionUngueltig {
            umfang = Farbauskunft.umfang(typ: nil, kennlinie: spur.colorTransfer,
                                         primaervalenzen: spur.colorPrimaries)
        }
        let basis: String?
        switch umfang {
        case .unbekannt, .dolbyVisionUngueltig: return nil
        case .sdr:       return "SDR"
        case .hdr10:     return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg:       return "HLG"
        case .dolbyVision:            basis = nil
        case .dolbyVisionHDR10:       basis = "HDR10"
        case .dolbyVisionHLG:         basis = "HLG"
        case .dolbyVisionSDR:         basis = "SDR"
        case .dolbyVisionEL:          basis = "EL"
        case .dolbyVisionHDR10Plus:   basis = "HDR10+"
        case .dolbyVisionELHDR10Plus: basis = "EL · HDR10+"
        }
        var text = "Dolby Vision"
        if let profil = dvProfilwort(profil: spur.dvProfile,
                                     kompatibel: spur.dvBlSignalCompatibilityId) {
            text += " P\(profil)"
        }
        if let basis { text += " · \(basis)" }
        return text
    }

    /// „8.1", „5", „7". Die Stelle nach dem Punkt gibt es nur bei den Profilen,
    /// die sie tragen (8 und 10) — ein „5.0" oder „7.6" steht so nirgends.
    static func dvProfilwort(profil: Int?, kompatibel: Int?) -> String? {
        guard let profil, profil > 0 else { return nil }
        if [8, 10].contains(profil), let kompatibel, kompatibel >= 0,
           !(profil == 8 && kompatibel == 0) {
            return "\(profil).\(kompatibel)"
        }
        return "\(profil)"
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
