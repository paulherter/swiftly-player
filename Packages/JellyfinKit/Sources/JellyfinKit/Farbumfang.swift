import Foundation

/// Welchen Dynamikumfang eine Videospur hat — so, wie der Server ihn meldet.
///
/// **Wofür.** Der Apple TV kann seinen HDMI-Ausgang auf HDR umstellen, aber
/// nur, wenn ihm jemand sagt, worauf. Die Angabe steht in Jellyfins Antwort
/// und wurde bisher schlicht nicht eingelesen; in `Bildtakt` steht dazu seit
/// Langem der Kommentar „welchen die Datei hat, weiß hier niemand".
///
/// **Doppelt gemoppelt ist hier richtig.** Jellyfin liefert `VideoRangeType`
/// *und* die rohen Angaben `ColorTransfer` und `ColorPrimaries`. Der Typ ist
/// die bequemere Auskunft, aber er kommt aus Jellyfins eigener Ableitung; die
/// rohen Werte stammen aus der Datei. Wo sie sich widersprechen, gilt die
/// Datei — und wo der Typ `Unknown` sagt, tragen die rohen Werte noch.
/// `Codable`, nicht nur `Decodable`: `MediaStream` ist auch `Encodable`,
/// weil es im Geräteprofil zurückgeht.
public enum Farbumfang: String, Sendable, Codable {
    case unbekannt        = "Unknown"
    case sdr              = "SDR"
    case hdr10            = "HDR10"
    case hlg              = "HLG"
    case dolbyVision      = "DOVI"
    case dolbyVisionHDR10 = "DOVIWithHDR10"
    case dolbyVisionHLG   = "DOVIWithHLG"
    case dolbyVisionSDR   = "DOVIWithSDR"
    case dolbyVisionEL    = "DOVIWithEL"
    case dolbyVisionHDR10Plus   = "DOVIWithHDR10Plus"
    case dolbyVisionELHDR10Plus = "DOVIWithELHDR10Plus"
    case dolbyVisionUngueltig   = "DOVIInvalid"
    case hdr10Plus        = "HDR10Plus"

    /// Ist das überhaupt ein erweiterter Umfang?
    public var istHDR: Bool {
        switch self {
        case .unbekannt, .sdr, .dolbyVisionSDR, .dolbyVisionUngueltig: false
        default: true
        }
    }

    /// **Welche Kennlinie der Ausgang braucht.**
    ///
    /// Zwei gibt es, und sie sind nicht austauschbar: PQ (SMPTE ST 2084) für
    /// HDR10 und Dolby Vision, HLG für Rundfunkmaterial. Wer die falsche
    /// setzt, bekommt kein „etwas anderes HDR", sondern ein sichtbar falsches
    /// Bild — zu dunkel oder ausgewaschen.
    public enum Kennlinie: Sendable, Equatable { case pq, hlg }

    public var kennlinie: Kennlinie? {
        switch self {
        case .hlg, .dolbyVisionHLG: .hlg
        case .hdr10, .hdr10Plus, .dolbyVision, .dolbyVisionHDR10,
             .dolbyVisionEL, .dolbyVisionHDR10Plus, .dolbyVisionELHDR10Plus: .pq
        case .unbekannt, .sdr, .dolbyVisionSDR, .dolbyVisionUngueltig: nil
        }
    }
}

/// Der Umfang, abgeleitet aus allem, was der Server sagt.
///
/// **Erst der Typ, dann die rohen Angaben.** Meldet Jellyfin `Unknown` —
/// etwa weil die Datei nie analysiert wurde —, tragen `ColorTransfer` und
/// `ColorPrimaries` die Auskunft trotzdem. Umgekehrt gilt: sagt keiner von
/// beiden etwas, wird **nichts** gesetzt. Geraten wäre schlimmer als
/// gelassen; ein HDR-Film in SDR sieht ausgewaschen aus, ein SDR-Film in HDR
/// flau.
public enum Farbauskunft {

    /// - Parameters:
    ///   - typ: Jellyfins `VideoRangeType`.
    ///   - kennlinie: Jellyfins `ColorTransfer` — „smpte2084", „arib-std-b67".
    ///   - primaervalenzen: Jellyfins `ColorPrimaries` — „bt2020".
    public static func umfang(typ: Farbumfang?,
                              kennlinie: String?,
                              primaervalenzen: String?) -> Farbumfang {
        if let typ, typ != .unbekannt { return typ }

        // Die Datei hat das letzte Wort, wenn der Typ schweigt.
        switch kennlinie?.lowercased() {
        case "smpte2084", "smpte-st-2084", "pq": return .hdr10
        case "arib-std-b67", "hlg":              return .hlg
        default: break
        }
        // Weite Primärvalenzen allein sind kein HDR — BT.2020 gibt es auch in
        // SDR. Deshalb hier nur „unbekannt", nicht geraten.
        _ = primaervalenzen
        return .unbekannt
    }
}
