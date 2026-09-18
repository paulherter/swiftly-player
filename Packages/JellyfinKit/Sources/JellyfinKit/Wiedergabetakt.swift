import Foundation

/// Ein Takt der Wiedergabebeobachtung — die Regeln, die beide Player brauchen.
///
/// Die Schleife lief zweimal, einmal je Plattform, und war in weiten Teilen
/// dieselbe: alle halbe Sekunde nachsehen, was die Zeichenfläche meldet, die
/// Zeit übernehmen oder eben nicht, den Ladeschirm wegnehmen, die Spuren
/// setzen, dem Server Bescheid geben.
///
/// **Der Zustand bleibt bei der Ansicht.** Diese Datei rechnet nur. Sie
/// bekommt den Stand herein, verändert ihn und sagt zurück, was danach zu tun
/// ist — Ladeschirm wegnehmen, Spuren anwenden, melden. Was das jeweils
/// bedeutet, weiß nur die Plattform: das iPhone schiebt dabei die
/// Steuerung-Ausblendung neu an, der Fernseher nicht.
///
/// Warum nicht als Klasse mit eigenem Zustand: die Ansichten halten ihre
/// Werte in `@State` und lesen sie an über siebzig Stellen. Sie alle
/// umzuhängen wäre ein großer Eingriff in einen ausgelieferten Player
/// gewesen, für nichts, was diese Datei nicht auch so leisten kann.
@MainActor
public enum Wiedergabetakt {

    /// Alle halbe Sekunde. Feiner braucht es niemand — die Anzeige zeigt
    /// Sekunden.
    ///
    /// **`nonisolated`, weil GTK den Takt nicht auf dem Hauptakteur startet.**
    /// Auf Linux legt `g_timeout_add_full` ihn aus einer nicht isolierten
    /// Methode an; ohne diese Angabe stand dort eine abgeschriebene 500, und
    /// B12 verlangt ausdrücklich **eine** Quelle für die Zahl. Ein
    /// unveränderliches `Sendable` darf den Akteur verlassen.
    public nonisolated static let taktlaenge: Duration = .milliseconds(500)
    /// Wie oft der Server den Fortschritt erfährt.
    public nonisolated static let meldeabstand: Double = 10

    /// Was die Ansicht zeigt und der Takt fortschreibt.
    public struct Stand: Sendable {
        public var position: Double = 0
        public var dauer: Double = 0
        public var laeuft = true
        public var erstesBildDa = false
        public var spurenGesetzt = false
        /// Dem Server ist einmal gesagt worden, dass es losging.
        public var startGemeldet = false
        /// Sekunden seit der letzten Fortschrittsmeldung.
        public var seitMeldung: Double = 0
        /// Der Titel kam über einen Folgenwechsel im laufenden Player — VLCs
        /// Uhr gehört anfangs noch dem Übergang (`Zeitannahme.position`).
        public var nachWechsel = false
        /// Ein Sprung, bei dem VLC noch nicht angekommen ist — solange zeigt
        /// die Anzeige die Zielstelle. Gesetzt über ``gesprungen(_:ziel:jetzt:)``.
        public var sprung: Sprung?

        public init(position: Double = 0, dauer: Double = 0, laeuft: Bool = true,
                    erstesBildDa: Bool = false, spurenGesetzt: Bool = false,
                    startGemeldet: Bool = false, seitMeldung: Double = 0) {
            self.position = position
            self.dauer = dauer
            self.laeuft = laeuft
            self.erstesBildDa = erstesBildDa
            self.spurenGesetzt = spurenGesetzt
            self.startGemeldet = startGemeldet
            self.seitMeldung = seitMeldung
        }
    }

    /// **Die Zielstelle eines Sprungs, bis VLC dort ist** (Bug 17.09.2026).
    ///
    /// Paul am iPhone: nach einem Doppeltipp stand die Zeit unten noch
    /// Sekunden auf der alten Stelle, und „Intro überspringen" kam und ging
    /// entsprechend spät. Gemessen im iOS-Simulator (`-sprunglauf`): VLC
    /// meldete die neue Zeit schon im nächsten Takt, die Anzeige blieb aber
    /// 2,0 s stehen — `spulen` setzte die Anzeige nicht auf das Ziel, und der
    /// Riegel, der sie vor VLCs alter Zeit schützen sollte, hielt stattdessen
    /// die neue fern, bis seine Frist ablief. Am Gerät, wo VLC nach einem
    /// Sprung auf das nächste Schlüsselbild wartet, dauerte es länger.
    ///
    /// Die Regel steht deshalb einmal hier und nicht je Sprungweg: **jeder**
    /// Sprung setzt die Anzeige sofort aufs Ziel, der Takt hält sie dort und
    /// übergibt an VLC, sobald VLC angekommen ist.
    public struct Sprung: Sendable, Equatable {
        public let ziel: Double
        public let seit: Date

        public init(ziel: Double, seit: Date = Date()) {
            self.ziel = ziel
            self.seit = seit
        }
    }

    /// Gesprungen: die Anzeige steht ab sofort auf dem Ziel.
    ///
    /// Auf die Dauer begrenzt, sobald sie bekannt ist — ein Sprung hinter das
    /// Ende zeigt sonst eine Zeit, die es nicht gibt.
    public nonisolated static func gesprungen(_ stand: inout Stand, ziel: Double,
                                              jetzt: Date = Date()) {
        var stelle = max(ziel, 0)
        if stand.dauer > 0 { stelle = min(stelle, stand.dauer) }
        stand.position = stelle
        stand.sprung = Sprung(ziel: stelle, seit: jetzt)
    }

    /// Wohin ein Sprung **um** `sekunden` führt: von der Zielstelle eines noch
    /// laufenden Sprungs aus, sonst von der angezeigten Stelle. Dreimal
    /// schnell vor sind dann 90 Sekunden, auch wenn VLC noch unterwegs ist.
    public nonisolated static func ziel(um sekunden: Double, stand: Stand) -> Double {
        (stand.sprung?.ziel ?? stand.position) + sekunden
    }

    /// Wie lange die Anzeige höchstens auf einem Ziel steht, bei dem VLC nie
    /// ankommt. `VLCPlayerView` versucht nach 2,5 s den zweiten Sprungweg und
    /// gibt nach weiteren 2,5 s auf; danach gilt wieder, was VLC sagt.
    public nonisolated static let sprungdeckel: TimeInterval = 8

    /// Was nach diesem Takt zu tun ist. Die Ansicht entscheidet, wie.
    public struct Auftrag: Sendable {
        public var ladeschirmWeg = false
        public var spurenAnwenden = false
        public var startMelden = false
        public var fortschrittMelden = false

        public init() {}
    }

    /// Was die Zeichenfläche in diesem Takt sagt.
    ///
    /// Als eigener Typ und nicht als `VLCPlayerView`, damit sich die Regeln
    /// ohne Player prüfen lassen.
    public struct Messung: Sendable {
        public let dauer: Double
        public let position: Double
        public let guteStelle: Double
        public let zeigtBild: Bool
        public let stelltEin: Bool
        public let laeuft: Bool
        public let hatTonspuren: Bool

        public init(dauer: Double, position: Double, guteStelle: Double,
                    zeigtBild: Bool, stelltEin: Bool, laeuft: Bool,
                    hatTonspuren: Bool) {
            self.dauer = dauer
            self.position = position
            self.guteStelle = guteStelle
            self.zeigtBild = zeigtBild
            self.stelltEin = stelltEin
            self.laeuft = laeuft
            self.hatTonspuren = hatTonspuren
        }
    }

    /// Ein neuer Titel läuft in derselben Schleife.
    ///
    /// Wer im laufenden Player die Folge wechselt, muss das hier sagen —
    /// sonst hält der Stand `startGemeldet` weiter für erledigt, und der
    /// Server erfährt vom nächsten Titel nur noch Fortschritt, ohne dass je
    /// eine Sitzung eröffnet wurde. Genau das ist auf dem Fernseher passiert.
    ///
    /// Die iPhone-Fassung meldet den Start beim Wechsel selbst und braucht
    /// das nicht; sie ruft stattdessen `startGemeldet: true` auf. Beide Wege
    /// sind richtig, solange einer davon gegangen wird — deshalb steht die
    /// Wahl hier und nicht im Gedächtnis dessen, der den Wechsel schreibt.
    public nonisolated static func neuerTitel(_ stand: inout Stand, startGemeldet: Bool) {
        stand.position = 0
        // **Auch das Bild.** Stand es nicht hier, ergänzte jede Plattform es
        // selbst — und macOS hatte es vergessen: kein Ladeschirm, und der Takt
        // übernahm gleich wieder die Zeit der alten Folge (Audit 16.09., T1-M3).
        stand.erstesBildDa = false
        stand.spurenGesetzt = false
        stand.startGemeldet = startGemeldet
        stand.seitMeldung = 0
        stand.nachWechsel = true
        stand.sprung = nil
    }

    /// **Die Anzeige zeigt VLCs Zeit — genau die, nichts hochgerechnet.**
    ///
    /// Einzige Ausnahme nach einem Sprung: die Zielstelle, bis VLC bis auf
    /// ``Zeitannahme/sprungAngekommen`` dort ist, dann sofort wieder VLCs Zeit,
    /// auch wenn sie ein Schlüsselbild vor dem Ziel liegt. (Eine erste Fassung
    /// hielt das Ziel, bis VLC es überholte; am iPhone stand die Zeit dadurch
    /// nach „30 s vor" still und wirkte danach, als zähle sie schneller —
    /// Paul, 17.09.2026.) Kommt VLC nie an, endet es nach ``sprungdeckel``.
    ///
    /// Eigene Funktion, damit eine Plattform die Anzeige öfter nachziehen kann
    /// als den ganzen Takt (``anzeigetakt``) — mit denselben Sperren.
    public nonisolated static func zeitUebernehmen(_ stand: inout Stand, gemeldet: Double,
                                                   amSchieben: Bool, seitStart: Date,
                                                   jetzt: Date = Date()) {
        guard !amSchieben else { return }
        if let sprung = stand.sprung {
            let angekommen = abs(gemeldet - sprung.ziel) < Zeitannahme.sprungAngekommen
            if angekommen || jetzt.timeIntervalSince(sprung.seit) >= sprungdeckel {
                stand.sprung = nil
                stand.position = gemeldet
            } else {
                stand.position = sprung.ziel
            }
            return
        }
        // Vor dem ersten Bild gar keine Zeit übernehmen: VLCs Angabe gehört
        // dann noch dem ungesprungenen Strom.
        guard stand.erstesBildDa else { return }
        if let uebernommen = Zeitannahme.position(gemeldet: gemeldet,
                                                  bisher: stand.position,
                                                  seitStart: seitStart,
                                                  nachWechsel: stand.nachWechsel) {
            stand.position = uebernommen
            stand.nachWechsel = false
        }
    }

    /// Wie oft die Anzeige VLCs Zeit nachzieht, wenn die Plattform das
    /// zwischen zwei Takten tut. Swiftfin und Streamyfin bekommen VLCs Zeit
    /// etwa viermal je Sekunde; mit einem halben Sekundentakt lief die
    /// Anzeige nach dem Abspielen spürbar verzögert an.
    public nonisolated static let anzeigetakt: Duration = .milliseconds(250)

    /// Ein Takt.
    ///
    /// - Parameters:
    ///   - stelltWiederHer: Läuft gerade ein Wiederaufbau nach Netzwechsel.
    ///     Dann gilt die letzte gute Stelle, nicht VLCs Zeit — die steht beim
    ///     toten Strom auf dem Dateiende.
    ///   - amSchieben: Der Finger liegt am Regler. Nur auf dem iPhone möglich;
    ///     der Fernseher übergibt `false`.
    /// **`nonisolated` wie `taktlaenge`:** die Android-Fassade ruft den Takt ueber JNI aus einem
    /// nicht isolierten Kontext, und dort arbeitet niemand die Hauptwarteschlange ab — ein Sprung
    /// auf den Hauptakteur hinge. Die Rechnung selbst beruehrt nur den hereingereichten Stand.
    public nonisolated static func rechnen(_ stand: inout Stand, messung: Messung,
                        stelltWiederHer: Bool,
                        amSchieben: Bool, seitStart: Date,
                        jetzt: Date = Date()) -> Auftrag {
        var auftrag = Auftrag()

        stand.dauer = messung.dauer

        // Der Ladeschirm darf weichen.
        if !stand.erstesBildDa,
           Zeitannahme.bildDa(zeigtBild: messung.zeigtBild,
                              stelltEin: messung.stelltEin,
                              seitStart: seitStart) {
            stand.erstesBildDa = true
            auftrag.ladeschirmWeg = true
        }

        // Die Zeit: VLCs, außer direkt nach einem Sprung (siehe dort).
        zeitUebernehmen(&stand, gemeldet: stelltWiederHer ? messung.guteStelle : messung.position,
                        amSchieben: amSchieben, seitStart: seitStart, jetzt: jetzt)

        // Spuren erst, wenn VLC sie kennt — vorher sind die Listen leer.
        if !stand.spurenGesetzt, stand.erstesBildDa, messung.hatTonspuren {
            stand.spurenGesetzt = true
            auftrag.spurenAnwenden = true
            // **Nach einem Folgenwechsel ist der Start schon draußen** — ohne
            // Spurindizes, denn VLC kannte die Spuren da noch nicht. Die
            // nächste Meldung trägt sie; sie kommt deshalb gleich, nicht erst
            // nach `meldeabstand`. Beim Öffnen geht der Start selbst nach den
            // Spuren hinaus und braucht das nicht.
            if stand.startGemeldet { stand.seitMeldung = meldeabstand }
        }

        if stand.erstesBildDa { stand.laeuft = messung.laeuft }

        // Ab hier geht es nur noch um den Server, und der will nichts hören,
        // solange nichts läuft.
        guard stand.erstesBildDa, stand.dauer > 0 else { return auftrag }

        // **Erst melden, wenn wirklich ein Bild steht.**
        //
        // Die iPhone-Fassung rief das früher gleich beim Öffnen. Dann führt
        // der Server aber schon eine Sitzung, während VLC noch aufzieht — auf
        // dem Fernseher dauert das spürbar länger, und dort fiel es auf. Die
        // vorsichtigere Fassung ist die gemeinsame geworden.
        if !stand.startGemeldet {
            stand.startGemeldet = true
            auftrag.startMelden = true
            return auftrag
        }

        stand.seitMeldung += taktlaenge / .seconds(1)
        if stand.seitMeldung >= meldeabstand {
            stand.seitMeldung = 0
            auftrag.fortschrittMelden = true
        }
        return auftrag
    }
}
