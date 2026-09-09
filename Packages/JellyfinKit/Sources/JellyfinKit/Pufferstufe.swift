import Foundation

/// **Wie viel Vorrat der Player haelt, bevor das Bild steht.**
///
/// Von einem Nutzer angestossen: „My internet connection isn't regular and
/// sometimes I don't have internet at all. So I would like to have a video
/// cache of 30s." Der Fall ist echt, die Zahl aber nicht uebertragbar — **der
/// Vorrat wird in Bytes gehalten, nicht in Sekunden.** Dieselben 16 MiB sind
/// bei einer 5-Mbit-Serie rund fuenfundzwanzig Sekunden und bei einem
/// 80-Mbit-Film knapp zwei. Wer „30 Sekunden" einstellt, bekaeme also je nach
/// Titel etwas voellig anderes.
///
/// Deshalb drei Stufen statt einer Zahl. Sie sagen, *wofuer* man sie waehlt,
/// und nicht, was intern passiert.
///
/// **Und jede Stufe kostet etwas.** Ein groesserer Vorrat heisst: laengeres
/// Anlaufen beim Start und nach jedem Sprung, denn er muss erst wieder
/// gefuellt werden. Genau deswegen ist `normal` die Vorgabe und nicht die
/// grosszuegigste Stufe — am 08.09.2026 wurde `network-caching=10000`
/// eingebaut und wieder entfernt, weil am Vorrat gar nichts fehlte: gemessen
/// lagen 211 Sekunden im Puffer, der Engpass sass hinter dem Demuxer.
public enum Pufferstufe: String, CaseIterable, Sendable, Codable {

    /// Wie bisher. Schnelle Spruenge, Vorrat aus dem Prefetch-Filter.
    case normal

    /// Fuer eine Leitung, die gelegentlich einbricht.
    case schlecht

    /// Fuer eine Leitung, die auch mal ganz weg ist.
    case sehrSchlecht

    /// Wie viel der Prefetch-Filter haelt, in KiB — VLCs eigene Einheit.
    ///
    /// 16 MiB ist der gemessene Wert von heute; die Stufen darueber
    /// vervierfachen und verzwoelffachen ihn. Mehr als 192 MiB waere auf einem
    /// Telefon unhoeflich: der Speicher gehoert nicht uns allein.
    public var prefetchKiB: Int {
        switch self {
        case .normal:       16_384
        case .schlecht:     65_536
        case .sehrSchlecht: 196_608
        }
    }

    /// VLCs Zeitvorlauf in Millisekunden, oder `nil` fuer „nicht anfassen".
    ///
    /// **Bei `normal` bewusst `nil` und nicht 1000.** VLCs Voreinstellung
    /// ausdruecklich noch einmal zu setzen sieht nach Absicht aus, aendert
    /// aber nichts — und wer spaeter danach sucht, haelt es fuer eine
    /// getroffene Entscheidung.
    public var netzvorlaufMillisekunden: Int? {
        switch self {
        case .normal:       nil
        case .schlecht:     15_000
        case .sehrSchlecht: 45_000
        }
    }

    /// Grobe Einordnung fuer die Oberflaeche: wie viele Sekunden das bei
    /// dieser Bitrate ungefaehr sind.
    ///
    /// **Ungefaehr, und das steht auch so da.** Die Bitrate schwankt innerhalb
    /// eines Films erheblich; eine Zahl auf die Sekunde genau waere gelogen.
    public func ungefaehrSekunden(bitsJeSekunde: Int) -> Int? {
        guard bitsJeSekunde > 0 else { return nil }
        let bytes = Double(prefetchKiB) * 1024
        return Int((bytes * 8 / Double(bitsJeSekunde)).rounded())
    }
}
