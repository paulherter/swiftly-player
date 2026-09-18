import Foundation

/// **Was dem Server als Bitratengrenze gemeldet wird.**
///
/// Die Rechnung ist zwei Zeilen lang und stand deshalb zweimal da: einmal in
/// `AppModel.profilBitrate`, einmal wortgleich in `Wahlen.profilBitrate` auf
/// Linux. Sie hat gerade deshalb hier zu stehen — an ihr haengt das
/// Versprechen der ganzen App. Ein Limit loest Transkodierung aus, auch wenn
/// Container und Codec passen; wer die Zahl an einer Stelle aendert und an
/// der anderen nicht, hat eine Plattform, die umrechnet, und eine, die es
/// nicht tut. Genau die Sorte Fehler, die man erst am Serverprotokoll merkt.
public enum Bitratengrenze {

    /// **Eine Milliarde heisst praktisch unbegrenzt.** Kein Limit zu senden
    /// waere die andere Moeglichkeit; Jellyfin behandelt „kein Wert" aber je
    /// nach Fassung anders, und eine Zahl, die keine Datei erreicht, ist die
    /// verlaesslichere Auskunft.
    public static let offen = 1_000_000_000

    /// - Parameters:
    ///   - immerDirectPlay: Die Einstellung „Immer Direct Play". Steht sie an,
    ///     gilt keine Grenze — das ist ihr ganzer Zweck.
    ///   - megabit: Die eingestellte Grenze in Mbit/s. `0` oder kleiner heisst
    ///     „keine".
    public static func fuer(immerDirectPlay: Bool, megabit: Int) -> Int {
        immerDirectPlay || megabit <= 0 ? offen : megabit * 1_000_000
    }
}
