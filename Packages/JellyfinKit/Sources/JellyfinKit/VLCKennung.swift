import Foundation

/// **libVLCs Vierzeichenkennung eines Codecs, richtig herum gelesen.**
///
/// libVLC baut die Kennung mit `VLC_FOURCC(a, b, c, d)` als
/// `a | b << 8 | c << 16 | d << 24` — das erste Zeichen liegt im
/// **niederwertigen** Byte. Am 16.09.2026 an VLCKit gemessen: `mp4a` kam so
/// heraus. Wer vom hochwertigen Byte her liest, bekommt `a4pm`, und jede
/// Tabelle dahinter fällt auf ihren Rückfall. Genau das tat die tvOS-Bildrate
/// (`Bildtakt.kennung`) und nahm dadurch jede Datei als HEVC.
///
/// Liegt im Paket, damit die Bytereihenfolge an **einer** Stelle steht und
/// geprüft wird — neben ``Technikangaben/codecname(vlcKennung:)``.
public enum VLCKennung {

    /// Die vier Zeichen, klein geschrieben, ohne Füllleerzeichen
    /// (`a52 ` wird `a52`). `nil` bei 0 oder wenn es kein ASCII ist.
    public static func zeichen(_ kennung: UInt32) -> String? {
        guard kennung != 0 else { return nil }
        let bytes = [kennung, kennung >> 8, kennung >> 16, kennung >> 24].map { UInt8($0 & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        let sauber = text.lowercased().trimmingCharacters(in: .whitespaces)
        return sauber.isEmpty ? nil : sauber
    }

    /// Der Videocodec in Jellyfins Schreibweise (`h264`, `hevc`, `vp9`, …),
    /// damit derselbe Vergleich greift wie für die Angabe des Servers.
    /// `nil`, wenn die Kennung unbekannt ist.
    public static func videocodec(_ kennung: UInt32) -> String? {
        switch zeichen(kennung) {
        case "h264", "avc1", "x264":         "h264"
        case "hevc", "hvc1", "hev1", "h265": "hevc"
        case "vp90", "vp09":                 "vp9"
        case "vp80":                         "vp8"
        case "av01":                         "av1"
        case "mp4v", "divx", "xvid", "dx50": "mpeg4"
        case "mpgv", "mp2v":                 "mpeg2video"
        default:                             nil
        }
    }
}
