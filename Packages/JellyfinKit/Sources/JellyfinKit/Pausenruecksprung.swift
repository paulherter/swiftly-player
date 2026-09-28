import Foundation

/// **Nach einer langen Pause ein paar Sekunden zurück — ohne dass man es
/// merkt.**
///
/// Wer eine Viertelstunde weg war, hat den letzten Satz vergessen. Andere
/// Player setzen beim Fortsetzen ein Stück zurück; hier geschieht es, bevor
/// das erste neue Bild kommt: die Stelle wird im Stehen gesetzt, dann läuft
/// es an. Kein Knopf, keine Einblendung, kein sichtbarer Sprung der Leiste.
///
/// Nicht in einer SyncPlay-Gruppe: dort bestimmt die Gruppe die Stelle, und
/// ein eigener Rücksprung liefe den anderen davon.
///
/// Die Regel steht im Paket, damit alle Plattformen dieselben Zahlen nehmen.
public enum Pausenruecksprung {

    /// Ab so langer Pause wird zurückgesetzt: zehn Minuten.
    public static let schwelle: TimeInterval = 600

    /// Um so viel: fünf Sekunden. Genug für den letzten Satz, zu wenig, um
    /// es als Wiederholung wahrzunehmen.
    public static let weite: Double = 5

    /// Wohin vor dem Weiterspielen gesprungen wird, oder `nil`, wenn nicht.
    ///
    /// - Parameters:
    ///   - position: die Stelle, an der angehalten wurde, in Sekunden.
    ///   - pausiertSeit: seit wann angehalten ist; `nil` heißt, es war nicht
    ///     angehalten.
    ///   - jetzt: der Moment des Weiterspielens.
    ///   - inGruppe: ob gerade gemeinsam geschaut wird.
    public static func ziel(position: Double, pausiertSeit: Date?, jetzt: Date,
                            inGruppe: Bool) -> Double? {
        guard !inGruppe, let pausiertSeit else { return nil }
        guard position.isFinite, position > 0 else { return nil }
        guard jetzt.timeIntervalSince(pausiertSeit) > schwelle else { return nil }
        return max(position - weite, 0)
    }
}
