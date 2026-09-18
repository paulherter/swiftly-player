import Foundation

/// Wann ein stehendes Bild ein Abriss ist — und wann bloß ein zäher Strom.
///
/// **Diese Regel hat einmal genau das Gegenteil bewirkt.** Gemessen an einer
/// HEVC-Folge, die minutenlang „lud": der Puffer stieg auf 52 %, sechs
/// Sekunden später riss die Notbremse den Strom ab, der Wiederaufbau kostete
/// zehn Sekunden samt neuem Sprung, und danach fing dasselbe von vorn an. Sie
/// hat den Hänger nicht behoben, sondern verewigt.
///
/// Deshalb steht sie hier und nicht mehr in ``VLCPlayer``: fünf Schwellen,
/// die zusammen entscheiden, ob ein Strom abgerissen wird. Vier Plattformen
/// benutzen dieselben, und eine falsche davon kostet den Zuschauer zehn
/// Sekunden Film — nachprüfbar ist sie nur, wenn sie ohne Abspieler läuft.
///
/// **Die Zahlen sind gemessen, nicht gewählt.** Wer eine ändert, ändert
/// Verhalten; die Begründung steht je Konstante daneben.
public enum Stromwacht {

    /// Wie lange ein Netzwechsel als Erklärung für einen Stillstand gilt.
    ///
    /// Danach ist er keine mehr: ein Bild, das zwei Minuten nach dem Wechsel
    /// steht, steht aus einem anderen Grund.
    public static let netzwechselFrist: TimeInterval = 90

    /// Stillstand, bevor eingegriffen wird — **nach** einem Netzwechsel.
    ///
    /// Kurz, weil der Grund dann bekannt ist und Warten nichts bringt.
    public static let stillstandNachWechsel: TimeInterval = 2

    /// Stillstand, bevor eingegriffen wird — sonst.
    ///
    /// Dreimal so lang: ohne bekannten Grund kann es auch ein zäher Server
    /// sein, und dort ist Geduld besser als ein Abriss.
    public static let stillstandNormal: TimeInterval = 6

    /// Ruhe nach jedem Sprungbefehl.
    ///
    /// Gemessen: bei einer Datei mit unlesbarem Index kam der Sprung auf
    /// keinem Weg an, die Bremse griff und riss den Strom ab, während VLC
    /// sich gerade vorwärts las. Das war einmal eine Minute, solange ein
    /// Sprung beliebig lange dauern konnte; seit dem mkv-Patch sitzt er in
    /// Millisekunden, und kürzer ist besser — solange die Frist läuft, ist
    /// die Absicherung gegen echte Abrisse ausgesetzt.
    public static let sprungruhe: TimeInterval = 20

    /// So frisch muss das letzte Pufferwachstum sein, damit gewartet wird.
    ///
    /// **Wer puffert, lebt — und dem reißt man nichts ab.** Die Bremse ist
    /// für Abrisse da: Funkloch, Serveraussetzer. Dort wächst nichts mehr.
    public static let pufferruhe: TimeInterval = 4

    /// Was die Wacht rät.
    ///
    /// Fünf Fälle statt eines `Bool`, damit das Protokoll sagen kann,
    /// **warum** gewartet wird. Beim Suchen nach einem Hänger ist genau das
    /// die Auskunft, auf die es ankommt.
    public enum Rat: Sendable, Equatable {
        /// Steht noch nicht lange genug.
        case nochNicht
        /// Ein Sprung ist unterwegs oder gerade erst befohlen.
        case sprungLaeuft
        /// Der Puffer wächst — der Strom lebt.
        case pufferWaechst
        /// Abriss. Strom neu aufbauen.
        case neuVerbinden
    }

    /// - Parameters:
    ///   - stillstandSeit: Wie lange das Bild schon steht.
    ///   - netzwechselVor: Wie lange der letzte Streckenwechsel her ist,
    ///     `nil`, wenn es keinen gab.
    ///   - sprungOffen: Ob gerade ein Sprung unterwegs ist.
    ///   - letzterSprungVor: Wie lange der letzte Sprungbefehl her ist.
    ///   - pufferWuchsVor: Wie lange das letzte Pufferwachstum her ist.
    public static func rat(stillstandSeit: TimeInterval,
                           netzwechselVor: TimeInterval?,
                           sprungOffen: Bool,
                           letzterSprungVor: TimeInterval,
                           pufferWuchsVor: TimeInterval) -> Rat {

        let frisch = netzwechselVor.map { $0 < netzwechselFrist } ?? false
        let noetig = frisch ? stillstandNachWechsel : stillstandNormal
        guard stillstandSeit >= noetig else { return .nochNicht }

        if sprungOffen || letzterSprungVor < sprungruhe { return .sprungLaeuft }
        if pufferWuchsVor < pufferruhe { return .pufferWaechst }
        return .neuVerbinden
    }
}
