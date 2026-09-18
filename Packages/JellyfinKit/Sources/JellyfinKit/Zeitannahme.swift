import Foundation

/// Wann VLCs Zeitangabe geglaubt werden darf — und wann nicht.
///
/// Das klingt nach einer Kleinigkeit und ist der Grund, warum ein
/// fortgesetzter Titel sichtbar am Anfang stand, bevor er an die richtige
/// Stelle sprang. Der Startsprung geht als Medienoption mit, VLC braucht
/// dafür aber ein paar Takte — und meldet in dieser Zeit Werte, die zum
/// **ungesprungenen** Strom gehören: erst null, dann die alte Zeit. Wer die
/// ungeprüft übernimmt, zeigt genau das an.
///
/// Die Regeln sind aus der iPhone-Fassung übernommen, wo sie erarbeitet
/// wurden. Sie liegen hier, damit beide Plattformen dieselben benutzen —
/// vorher hatte der Fernseher gar keine.
public enum Zeitannahme {

    /// Wie lange die Anzeige nach einem Sprung nicht überschrieben wird —
    /// **als Deckel, nicht als Wartezeit.**
    ///
    /// Der Riegel fällt, sobald der Abspieler dort steht, wo er hinsollte;
    /// diese Frist greift nur, wenn ein Sprung gar nicht ankommt. Ohne sie
    /// bliebe die Anzeige bei einer kaputten Datei für immer stehen.
    ///
    /// **Sie stand einmal vierfach da, mit drei verschiedenen Werten:**
    /// tvOS 1,2 s, macOS 2 s, iOS 2 s — und einmal 1,5 s im Spulen, ohne
    /// Begründung. Verschieden war dabei nicht der Wert, sondern das
    /// Verfahren: nur tvOS löste den Riegel früh, die anderen sassen ihre
    /// Frist immer ab. Seit alle drei früh lösen, ist der Wert nur noch der
    /// Deckel — und dann gibt es keinen Grund für drei davon.
    ///
    /// Gefunden von der tvOS-Sitzung im Tiefendurchgang am 03.09.2026.
    public static let sprungriegel: TimeInterval = 2

    /// Wie nah der Abspieler am Ziel sein muss, damit der Sprung als
    /// angekommen gilt.
    ///
    /// Zwei Sekunden: enger wäre bei einem Strom, der nur auf Schlüsselbilder
    /// springen kann, zu streng — dort landet man regelmäßig eine Sekunde
    /// daneben, und der Riegel fiele nie.
    public static let sprungAngekommen: Double = 2


    /// Wie lange nach dem Öffnen ein Rücksprung als Aufbauzucken gilt.
    public static let frischeFenster: TimeInterval = 8
    /// Ab wann der Ladeschirm auf jeden Fall weicht.
    public static let notbremse: TimeInterval = 12

    /// Dieselbe Notbremse, solange VLC noch auf die Startstelle einsteuert.
    ///
    /// Zwölf Sekunden waren zu kurz. `VLCPlayerView` steuert die Startstelle
    /// nach dem ersten Bild an und gibt erst nach **zwanzig** Sekunden auf;
    /// bei großen Dateien dauert das länger als zwölf. Der Ladeschirm wich
    /// dann mitten im Einsteuern, und man sah den Film bei Sekunde null
    /// anlaufen, bis der Sprung saß — genau der Fehler, den diese Datei
    /// verhindern soll. Aufgefallen ist es auf dem Fernseher, bei Filmen;
    /// Folgen sind kleiner und waren rechtzeitig fertig.
    ///
    /// Liegt bewusst **hinter** VLCs eigener Aufgabefrist, damit sie nicht
    /// mitten hineingreift.
    public static let einsteuerFrist: TimeInterval = 25

    /// Ob der Ladeschirm weichen darf.
    ///
    /// `zeigtBild` allein genügt nicht: solange VLC noch einstellt, gehört
    /// das Bild dem alten Stand. Die Notbremse ist trotzdem nötig — der
    /// Ladeschirm darf nie dauerhaft stehenbleiben, auch wenn darunter etwas
    /// klemmt. Genau das ist einmal passiert: Ton lief, Bild blieb verdeckt.
    public static func bildDa(zeigtBild: Bool, stelltEin: Bool, seitStart: Date) -> Bool {
        let seit = Date().timeIntervalSince(seitStart)
        // Solange eingesteuert wird, gilt die längere Frist — sonst hebelt
        // die Notbremse genau das aus, was sie absichern soll.
        if stelltEin { return seit > einsteuerFrist }
        if seit > notbremse { return true }
        return zeigtBild
    }

    /// Welche Zeit die Anzeige übernimmt — oder `nil`, wenn keine.
    ///
    /// Zwei Sperren:
    ///
    /// 1. **Unter einer halben Sekunde nichts.** VLC meldet beim Öffnen und
    ///    unmittelbar nach dem Startsprung für ein, zwei Takte noch null.
    /// 2. **Kein Rücksprung kurz nach dem Öffnen.** Springt die Zeit um mehr
    ///    als dreißig Sekunden zurück, während der Titel frisch offen ist,
    ///    ist das der ungesprungene Strom und nicht der Zuschauer.
    public static func position(gemeldet: Double, bisher: Double, seitStart: Date) -> Double? {
        guard gemeldet > 0.5 else { return nil }
        let rueckwaerts = gemeldet < bisher - 30
        let frischGeoeffnet = Date().timeIntervalSince(seitStart) < frischeFenster
        guard !(rueckwaerts && frischGeoeffnet) else { return nil }
        return gemeldet
    }
}
