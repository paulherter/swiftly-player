import Foundation

/// **Ob libVLC ein anamorphes Bild verdreht hat — und was stattdessen gilt.**
///
/// libVLC 4 (VLCKit 4.0.0-a23) liest bei Matroska `DisplayUnit = 3`
/// („Seitenverhältnis") das Pixelverhältnis falsch herum: aus 64:45 wird
/// 45:64. ffmpeg schreibt anamorphe MKV genau so, also auch alles, was über
/// libavformat entsteht (HandBrake). Gemessen 25.09.2026 an einer PAL-Datei
/// 720×576, 16:9: VLC 4 verlangt ein Fenster von 506×576 statt 1024×576 —
/// das Bild ist gestaucht. libVLC 3 (Linux, Windows, Android) rechnet
/// richtig. Upstream behoben in VLC `74a3aae62e` (18.09.2026), in unserem
/// VLCKit noch nicht.
///
/// Erkannt wird der Fehler an genau seiner Form: VLCs Pixelverhältnis ist
/// der **Kehrwert** dessen, was aus Jellyfins Anzeigeverhältnis folgt. Alles
/// andere bleibt VLC überlassen — ein richtig gelesenes Bild wird nicht
/// angefasst, und sobald ein VLCKit mit dem Fix kommt, greift das hier nicht
/// mehr.
public enum Seitenverhaeltnis {

    /// „16:9", „2.35:1" → Breite durch Höhe.
    static func wert(_ text: String?) -> Double? {
        guard let teile = text?.split(separator: ":"), teile.count == 2,
              let a = Double(teile[0]), let b = Double(teile[1]), a > 0, b > 0 else { return nil }
        return a / b
    }

    /// - Parameters:
    ///   - sar: Pixelverhältnis, wie VLC es meldet (Zähler, Nenner).
    ///   - breite, hoehe: Bildgröße vom Server.
    ///   - anzeige: Jellyfins `AspectRatio`.
    /// - Returns: das Anzeigeverhältnis, das VLC erzwungen werden muss, oder
    ///   `nil`, wenn nichts zu tun ist.
    public static func korrektur(sar: (UInt32, UInt32), breite: Int, hoehe: Int,
                                 anzeige: String?) -> String? {
        guard sar.0 > 0, sar.1 > 0, breite > 0, hoehe > 0, let dar = wert(anzeige) else { return nil }
        let erwartet = dar * Double(hoehe) / Double(breite)
        let vlc = Double(sar.0) / Double(sar.1)
        let nah = { (a: Double, b: Double) in abs(a - b) / b < 0.02 }
        guard !nah(erwartet, 1), !nah(vlc, erwartet), nah(vlc * erwartet, 1) else { return nil }
        return anzeige
    }
}
