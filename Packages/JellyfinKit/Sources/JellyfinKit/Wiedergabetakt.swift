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
    public static let taktlaenge: Duration = .milliseconds(500)
    /// Wie oft der Server den Fortschritt erfährt.
    public static let meldeabstand: Double = 10

    /// Was die Ansicht zeigt und der Takt fortschreibt.
    public struct Stand {
        public var position: Double = 0
        public var dauer: Double = 0
        public var laeuft = true
        public var erstesBildDa = false
        public var spurenGesetzt = false
        /// Dem Server ist einmal gesagt worden, dass es losging.
        public var startGemeldet = false
        /// Sekunden seit der letzten Fortschrittsmeldung.
        public var seitMeldung: Double = 0

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

    /// Was nach diesem Takt zu tun ist. Die Ansicht entscheidet, wie.
    public struct Auftrag {
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
    public struct Messung {
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
    public static func neuerTitel(_ stand: inout Stand, startGemeldet: Bool) {
        stand.position = 0
        stand.spurenGesetzt = false
        stand.startGemeldet = startGemeldet
        stand.seitMeldung = 0
    }

    /// Ein Takt.
    ///
    /// - Parameters:
    ///   - stelltWiederHer: Läuft gerade ein Wiederaufbau nach Netzwechsel.
    ///     Dann gilt die letzte gute Stelle, nicht VLCs Zeit — die steht beim
    ///     toten Strom auf dem Dateiende.
    ///   - sprungLaeuft: Es wurde eben gesprungen und noch nicht angekommen.
    ///   - amSchieben: Der Finger liegt am Regler. Nur auf dem iPhone möglich;
    ///     der Fernseher übergibt `false`.
    public static func rechnen(_ stand: inout Stand, messung: Messung,
                        stelltWiederHer: Bool, sprungLaeuft: Bool,
                        amSchieben: Bool, seitStart: Date) -> Auftrag {
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

        // Vor dem ersten Bild gar keine Zeit übernehmen: VLCs Angabe gehört
        // dann noch dem ungesprungenen Strom.
        if stand.erstesBildDa, !amSchieben, !sprungLaeuft {
            let gemeldet = stelltWiederHer ? messung.guteStelle : messung.position
            if let uebernommen = Zeitannahme.position(gemeldet: gemeldet,
                                                      bisher: stand.position,
                                                      seitStart: seitStart) {
                stand.position = uebernommen
            }
        }

        // Spuren erst, wenn VLC sie kennt — vorher sind die Listen leer.
        if !stand.spurenGesetzt, stand.erstesBildDa, messung.hatTonspuren {
            stand.spurenGesetzt = true
            auftrag.spurenAnwenden = true
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

        stand.seitMeldung += 0.5
        if stand.seitMeldung >= meldeabstand {
            stand.seitMeldung = 0
            auftrag.fortschrittMelden = true
        }
        return auftrag
    }
}
