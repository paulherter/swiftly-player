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

    /// Wie nah der Abspieler am Ziel sein muss, damit der Sprung als
    /// angekommen gilt.
    ///
    /// Zwei Sekunden: enger wäre bei einem Strom, der nur auf Schlüsselbilder
    /// springen kann, zu streng — dort landet man regelmäßig eine Sekunde
    /// daneben, und die Anzeige käme nie von der Zielstelle los. Wie lange sie
    /// höchstens dort bleibt, sagt ``Wiedergabetakt/sprungdeckel``.
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

    /// Ob die Bildausgabe dem **laufenden** Medium gehört.
    ///
    /// Wechselt der Player die Folge, ohne die Fläche abzubauen, hält VLC die
    /// Bildausgabe (`hasVideoOut`) und die Uhr der alten Folge noch, bis die
    /// neue ihr erstes Bild hat. Der Takt nahm das als „Bild steht", übernahm
    /// die alte Zeit (75 s statt 0) und meldete sie für die neue Folge; bis
    /// `frischeFenster` um war, galt die echte Zeit als Rücksprung und wurde
    /// verworfen. Gemessen am 17.09. auf dem tvOS-Simulator: `Progress 76 s`
    /// sechs Sekunden nach dem Wechsel, dann `14 s`.
    ///
    /// Die Bildzahl steht am Medium, nicht am Player — ein neues Medium
    /// fängt bei null an. Beim ersten Öffnen gibt es nichts Altes.
    public static func bildGehoertDemMedium(bildausgabe: Bool, gezeigteBilder: UInt64,
                                            nachWechsel: Bool) -> Bool {
        bildausgabe && (!nachWechsel || gezeigteBilder > 0)
    }

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
    /// 3. **Nach einem Folgenwechsel nichts, was noch nicht gespielt sein
    ///    kann.** Die neue Folge beginnt bei null; mehr als die vergangene
    ///    Zeit plus `wechselSpielraum` ist VLCs Uhr aus dem Übergang. Gemessen
    ///    am 17.09. (tvOS-Simulator): zuerst die alte Stelle (76 s), mit
    ///    dem ersten Bild der neuen Folge dann 6130 s — beides ging als
    ///    Fortschritt an den Server, und „Nächste Folge" blitzte auf.
    ///    Weil Sperre 2 die echte Zeit danach als Rücksprung verwarf, stand
    ///    die Anzeige acht Sekunden falsch. Gilt bis zur ersten
    ///    übernommenen Zeit (der Takt löscht `nachWechsel` dann), höchstens
    ///    `einsteuerFrist` lang — ein langsamer Aufbau dauert länger als das
    ///    Frischefenster.
    public static func position(gemeldet: Double, bisher: Double, seitStart: Date,
                                nachWechsel: Bool = false) -> Double? {
        guard gemeldet > 0.5 else { return nil }
        let seit = Date().timeIntervalSince(seitStart)
        let frischGeoeffnet = seit < frischeFenster
        if nachWechsel, seit < einsteuerFrist, gemeldet > seit + wechselSpielraum { return nil }
        let rueckwaerts = gemeldet < bisher - 30
        guard !(rueckwaerts && frischGeoeffnet) else { return nil }
        return gemeldet
    }

    /// Wie weit die Uhr der neuen Folge der Wanduhr voraus sein darf —
    /// Puffer, der schon vor `seitStart` gelesen war, und Taktversatz.
    public static let wechselSpielraum: TimeInterval = 5
}
