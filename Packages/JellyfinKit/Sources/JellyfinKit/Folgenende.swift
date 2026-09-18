import Foundation

/// Wann eine Folge als „zu Ende" gilt — und was dann passiert.
///
/// Zwei Fragen, die leicht verwechselt werden und deshalb auseinanderliefen:
/// wann der **Knopf** erscheint, und wann von selbst **weitergeschaltet**
/// wird. Das eine ist ein Angebot, das andere eine Handlung.
///
/// Die Regeln standen vorher zweimal da: einmal in der iPhone-Fassung,
/// einmal auf dem Fernseher. Inhaltlich stimmten sie überein — bis auf die
/// Vergleiche, `>` gegen `>=`, was für sich folgenlos ist. Der Grund fürs
/// Zusammenlegen ist deshalb nicht ein gefundener Fehler, sondern die
/// Aussicht auf einen: zwei Fassungen derselben Frage laufen mit der Zeit
/// auseinander, und bei `Titelangaben` ist genau das schon passiert.
///
/// Maßgeblich ist die iPhone-Fassung, dort wurden die Zahlen erarbeitet.
public enum Folgenende {

    /// Unterhalb dieser Laufzeit wird gar nicht geprüft.
    ///
    /// Sonst steht der Knopf bei einem Vorspann oder einem kurzen Extra
    /// praktisch immer im Bild — bei fünf Minuten wären die letzten
    /// zweieinhalb schon „gegen Ende".
    public static let mindestlaufzeit: Double = 300

    /// Ab hier gilt eine Folge als fast durch: zweieinhalb Minuten vor
    /// Schluss oder ab 96 Prozent, je nachdem was früher eintritt.
    public static let restsekunden: Double = 150
    public static let anteil: Double = 0.96

    /// Ob der Knopf „Nächste Folge" angeboten wird.
    ///
    /// Ein Angebot, keine Handlung — deshalb großzügig bemessen. Bei einem
    /// Zweistünder stünde er sonst zwei Stunden lang im Weg.
    public static func knopfZeigen(position: Double, dauer: Double) -> Bool {
        guard dauer > mindestlaufzeit else { return false }
        return (dauer - position) <= restsekunden || (position / dauer) >= anteil
    }

    /// Wie lange nach dem Oeffnen nicht von selbst weitergeschaltet wird.
    ///
    /// **Ohne diese Frist schaltet ein frisch geoeffneter Strom sofort
    /// weiter.** Gemessen am 04.09.2026: eine Folge wurde mit
    /// `:start-time=3721` geoeffnet, VLC meldete die Position augenblicklich
    /// als 3721 s — die Laenge dagegen war in denselben Millisekunden noch
    /// nicht verlaesslich. `position >= dauer - 1` war damit wahr, 629 ms
    /// nach dem Oeffnen lief die naechste Folge, und Paul hat dreimal
    /// dieselbe Folge nicht zu sehen bekommen.
    ///
    /// Die Frist ist auch ohne Startsprung richtig: eine Folge, die gerade
    /// erst aufgeht, ist nicht zu Ende. Kein Zuschauer verliert etwas,
    /// niemand merkt die Verzoegerung — und der Fall, den sie verhindert,
    /// kostet die ganze Folge.
    public static let anlaufruhe: Double = 5

    /// Ob von selbst zur naechsten Folge gewechselt wird.
    ///
    /// Deutlich enger gefasst als der Knopf: hier wird gehandelt, ohne dass
    /// jemand darum gebeten hat. Erst wenn wirklich nichts mehr kommt — und
    /// fruehestens ``anlaufruhe`` Sekunden nach dem Oeffnen.
    public static func weiterschalten(position: Double, dauer: Double,
                                      seitOeffnen: Double) -> Bool {
        guard seitOeffnen > anlaufruhe else { return false }
        guard dauer > 60 else { return false }
        return position >= dauer - 1
    }
}
