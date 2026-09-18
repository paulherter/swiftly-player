import SwiftUI

/// Maße, Schriftgrößen und Grundformen für den Mac.
///
/// Die Farben stehen in `Sources/Shared/Farben.swift` und sind mit iPhone und
/// Fernseher identisch. Alles hier ist neu, und zwar aus genau zwei Gründen:
/// **Zeiger statt Finger** und **Fenster statt Bildschirm**.
///
/// Die Schriftstufen bleiben dieselben wie auf dem iPhone — 28 / 20 / 16 / 15
/// / 14 / 12 / 10. Ein Mac steht kaum weiter weg als ein Telefon in der Hand;
/// was sich ändert, ist die Fläche, nicht die Leseentfernung. Übernommen
/// bleiben auch alle Seitenverhältnisse: Poster 2 : 3, Querkachel 16 : 9.
/// Nur die absoluten Werte wachsen mit.
extension Stil {

    // MARK: Fenster

    /// Kleinste Fenstergröße, unter der das Raster nicht mehr aufgeht:
    /// Seitenleiste plus zwei Kachelspalten plus Ränder.
    static let fensterMinBreite: CGFloat = 900
    static let fensterMinHoehe: CGFloat = 560

    /// Platz für die Fensterampel — **nur in der Seitenleiste.**
    ///
    /// Die drei Punkte sitzen oben links im Fenster, also über der
    /// Seitenleiste. Sie enden bei rund 27; die Wortmarke bringt zudem
    /// eigene Luft mit, weil ihre Vorlage das Zeichen über dem „i" und die
    /// Unterlänge des „y" einschließt und die Buchstaben nur die halbe Höhe
    /// füllen. 40 reicht deshalb, wo vorher 52 standen.
    /// Wie weit von oben die Zone reicht, in der die Fensterampel im Player
    /// erscheint. Etwas grosszuegiger als die Ampel selbst, damit man sie
    /// nicht suchen muss.
    static let ampelzone: CGFloat = 90

    static let ampelHoehe: CGFloat = 40

    /// Oberer Rand im **Inhaltsbereich**.
    ///
    /// Hier gibt es nichts freizuhalten: der Inhalt beginnt rechts der
    /// Seitenleiste, die Ampel liegt gar nicht darüber. Vorher standen hier
    /// dieselben 52 wie links — Platz für etwas, das dort nie war.
    static let inhaltOben: CGFloat = 52

    /// **Optischer Ausgleich für die Startseite.**
    ///
    /// „Filme" und „Serien" stehen als 28-Punkt-Titel oben auf ihrer Seite,
    /// die Startseite beginnt mit „Weiterschauen" in 20 Punkt. Bei gleichem
    /// Abstand von oben stehen sie damit **nicht** gleich hoch: über den
    /// Versalien lässt eine Zeile Platz, und der wächst mit dem Schriftgrad.
    ///
    /// Nachgemessen an den Schriftmaßen: 28 Punkt fett lässt 7,34 Punkt über
    /// der Versalhöhe frei, 20 Punkt halbfett nur 5,24. Die Startseite muss
    /// also um die Differenz tiefer ansetzen, damit die Oberkanten der
    /// Buchstaben auf einer Linie liegen.
    static let reihenkopfAusgleich: CGFloat = 2.1

    /// Höhe der Kopfleiste einer Detailseite (Pfeil und einblendender Titel).
    static let titelHoehe: CGFloat = 52

    static let seitenleisteBreite: CGFloat = 220

    // MARK: Maße

    static let ecke: CGFloat = 6
    static let eckeKachel: CGFloat = 8
    static let eckeFeld: CGFloat = 10
    static let randAbstand: CGFloat = 24
    static let kachelAbstand: CGFloat = 12
    static let reihenAbstand: CGFloat = 28

    /// Poster, 2 : 3 — auf dem iPhone 112 × 168.
    static let kachelBreite: CGFloat = 150
    static let kachelHoehe: CGFloat = 225

    /// Weiterschauen liegt quer, 16 : 9 — auf dem iPhone 240 × 135.
    static let querBreite: CGFloat = 280
    static let querHoehe: CGFloat = 158

    /// Die Kopfzone der Detailseite.
    ///
    /// **Genau der Inhalt, keine Restluft**: 150 oben plus 230 Block.
    ///
    /// Die Luft liegt vollständig **oben**. Unten darf keine sein: der
    /// Abstand von der Knopfreihe zur ersten Überschrift soll derselbe sein
    /// wie zwischen allen anderen Abschnitten (26). Jede Restluft in dieser
    /// Zone käme dort obendrauf, und die Reihe „Besetzung" stünde weiter
    /// entfernt als „Ähnliches" von der Reihe darüber.
    static let heldHoehe: CGFloat = 380

    // MARK: Tippflächen — kleiner als auf dem iPhone

    /// Ein Zeiger trifft genauer als ein Finger. Apples eigene Seitenleisten
    /// stehen auf 28; 32 gibt der Schrift von 15 etwas mehr Luft.
    static let zeileHoehe: CGFloat = 32
    /// Runde Aktionsknöpfe auf den Detailseiten — auf dem iPhone 44.
    static let knopfRund: CGFloat = 40
    /// Der Hauptknopf bleibt 48 hoch, aber **nicht** über die volle Breite:
    /// ein Zeiger trifft einen Knopf, ein Daumen braucht die Fläche.
    static let hauptknopfHoehe: CGFloat = 48

    /// **Feste Breite des Hauptknopfes.**
    ///
    /// Sonst richtet sich der ganze Rest der Reihe nach der Länge der
    /// Beschriftung, und Merkliste und Mehr stehen auf jeder Seite woanders.
    /// 200 trägt „Fortsetzen" wie „Abspielen" mit Luft.
    static let hauptknopfBreite: CGFloat = 200

    // MARK: Schrift — dieselbe Abstufung wie auf dem iPhone

    static let titelGross = Font.system(size: 28, weight: .bold)
    static let titel      = Font.system(size: 22, weight: .semibold)
    static let reihe      = Font.system(size: 20, weight: .semibold)
    static let leiste     = Font.system(size: 17, weight: .semibold)
    static let listentitel = Font.system(size: 15, weight: .semibold)
    static let koerper    = Font.system(size: 15)
    static let kachelTitel = Font.system(size: 14, weight: .medium)
    static let zweitzeile = Font.system(size: 12)
    static let plakette   = Font.system(size: 10, weight: .semibold)
    static let rubrik     = Font.system(size: 11, weight: .semibold)

    // MARK: Zeiten — wörtlich aus der iPhone-Fassung

    static let zeitUmschalten = Animation.easeOut(duration: 0.10)
    static let zeitSchweben   = Animation.easeOut(duration: 0.12)
    static let zeitSprung     = Animation.snappy(duration: 0.22)

    // MARK: Seitenwechsel — drei Bewegungen, an drei Bedeutungen gebunden
    //
    // Vorher tat jede Stelle etwas anderes: der Bereichswechsel gar nichts,
    // der Phasenwechsel `.default`, der Player eine eigene Zeit. Von außen
    // sah das aus, als starte die App mal mit und mal ohne Animation.
    //
    // Die Regel: **Was die Bewegung bedeutet, bestimmt, wie sie aussieht.**
    //
    //   Ersetzen     Der Inhaltsbereich zeigt etwas anderes — Start gegen
    //                Filme, Anmeldung gegen Bibliothek. Nichts wandert,
    //                also blendet es über.
    //   Tiefer       Eine Ebene hinein: Detailseite, Einstellungen. Das
    //                schiebt von rechts, und den Weg zurück kennt man.
    //                Macht `NavigationStack` von sich aus.
    //   Aufsteigen   Der Player nimmt das ganze Fenster. Er kommt von unten
    //                und geht dorthin zurück — deshalb zeigt der Winkel oben
    //                links nach unten.

    /// Wenn nachgeladener Inhalt an die Stelle eines Laders tritt. Er soll
    /// eintreten, nicht erscheinen — sonst liest sich das Nachladen als
    /// Sprung, auch wenn nichts ruckelt.
    static let zeitEinblenden = Animation.easeOut(duration: 0.25)

    // MARK: Der Wechsel in der Leiste — „Fade Through"
    //
    // **Nachgelesen, nicht ausgedacht.** Der Übergang hat einen Namen und
    // eine veröffentlichte Vorschrift: das Ausgehende blendet in 100 ms aus,
    // **danach** blendet das Eingehende in 200 ms ein und wächst dabei von
    // 92 % auf 100 %. Nacheinander, nicht überlappend.
    //
    // Die 92 % sind ausdrücklich so gewählt und nicht kleiner: der Übergang
    // soll die Aufmerksamkeit nicht auf sich ziehen. Genau deshalb sieht man
    // ihn kaum und findet ihn trotzdem angenehm.
    //
    // Gedacht ist er für Inhalte **ohne starke Beziehung zueinander** — und
    // der Wechsel zwischen Tabs wird in der Vorschrift wörtlich als der
    // passende Fall genannt.
    //
    // Zur Einordnung: eine macOS-Seitenleiste schaltet sonst ohne Blende um
    // (Finder, Mail, Systemeinstellungen). Das hier ist eine bewusste
    // Abweichung, Pauls Entscheidung — und sie trägt erst, seit die Stände
    // der Bereiche liegen bleiben. Solange jeder Wechsel neu geladen hat,
    // hätte eine Blende die Wartezeit nur verlängert.

    /// Das Alte geht. Nur blenden, nicht schrumpfen.
    ///
    /// **Und es überlappt jetzt mit dem Kommenden.** Die Vorschrift trennt
    /// beides sauber: erst 100 ms ganz hinaus, dann herein. Auf einem
    /// Telefonbildschirm ist diese Lücke ein Wimpernschlag, in einem grossen
    /// Fenster ist sie ein **leerer Bildschirm** — und das war vermutlich das
    /// Harte daran, nicht die Stärke der Mittel. Jetzt gehen die beiden
    /// ineinander über, und es ist nie nichts zu sehen.
    static let zeitBereichHinaus = Animation.easeInOut(duration: 0.20)
    /// Das Neue kommt — erst danach, deshalb der Vorlauf.
    static let zeitBereichHerein = Animation.easeOut(duration: 0.26).delay(0.04)

    // **Und warum hier keine Skalierung mehr steht.**
    //
    // Die Vorschrift lässt das Eingehende von 92 % wachsen. Eine Skalierung
    // verschiebt aber jeden Punkt proportional zu seinem Abstand vom
    // Mittelpunkt — auf einem Telefon sind das an der Kante wenige Punkte,
    // in einem Fenster von 1500 Punkt Breite bei nur einem Prozent schon
    // acht, und ein Fenster ist breiter als hoch. Die Verschiebung ist damit
    // seitlich am grössten, also genau dort, wo die Kachelreihen enden.
    //
    // Paul hat es an der untersten Reihe gesehen: „die zoomt rein und bewegt
    // sich von rechts nach links". Sie tat es. Das ist keine Einstellungs-
    // frage — es folgt aus der Skalierung selbst und lässt sich nur
    // verkleinern, nicht abstellen.
    //
    // Deshalb Unschärfe statt Skalierung: sie gibt dieselbe Tiefe und
    // verschiebt nichts.
    //
    // `.blurReplace`, Apples fertiger Übergang dafür, war ebenfalls zu
    // kräftig — er bringt seine eigene Skalierung mit und lässt sich nicht
    // dosieren. Deshalb hier von Hand, mit drei Zahlen, die einzeln
    // einstellbar sind.

    /// Wie weich das Neue anfängt. Das ist der Anteil, den man sehen soll.
    /// Paul hat den Wert am laufenden Bild eingestellt; 14, 5 und 3 waren
    /// alle zu viel. Unschärfe fällt in einem grossen Fenster deutlich mehr
    /// auf als auf einem Telefon — sie trifft ja jeden Text auf der ganzen
    /// Fläche gleichzeitig.
    static let bereichUnschaerfe: CGFloat = 0.8
    /// Und wie wenig es dabei wächst. Der Weg hierher, alles am laufenden
    /// Bild: 92 % (Vorschrift, viel zu viel), 98, 99, 99,5 — und 99,8 war
    /// gar nicht mehr wahrnehmbar. 99,6 legt an der Fensterkante rund drei
    /// Punkte zurück; das ist der schmale Streifen dazwischen.
    static let bereichKleiner: CGFloat = 0.996

    /// Überblenden beim Ersetzen. 180 ms ease-out — dieselbe Zeit, in der auf
    /// dem iPhone die Player-Steuerung erscheint.
    static let zeitSeite = Animation.easeOut(duration: 0.18)

    /// Das Schieben beim Tiefergehen.
    ///
    /// **Nachgemessen, nicht geschätzt.** Der Verlauf wurde Einzelbild für
    /// Einzelbild mitgeschrieben; die Zahlen unten stammen daraus.
    ///
    /// `smooth(0.50)` — eine Feder — sah auf dem Papier richtig aus und war
    /// es nicht: sie legte **90 % der Strecke in 320 ms** zurück und kroch
    /// die restlichen zehn Prozent über 1,2 Sekunden hinterher. Vorne ein
    /// Wusch, hinten nichts. Genau das heisst „zu schnell und hart", obwohl
    /// „0,5 Sekunden" daneben steht: bei einer Feder ist die Dauer ein
    /// Empfinden, keine Strecke.
    ///
    /// `easeInOut` verteilt gleichmässig — die Hälfte der Strecke in der
    /// Hälfte der Zeit — und hört auf, wenn sie fertig ist. 450 ms, also die
    /// Hälfte länger als die 300, die zu kurz waren.
    static let zeitSeitenschub = Animation.easeInOut(duration: 0.45)
}

/// Wie ein Bereich hereinkommt: **Unschärfe zuerst, Zoom fast keiner.**
///
/// Von Hand statt `.blurReplace`, weil dessen Anteile feststehen. Hier sind
/// sie drei Zahlen in `Stil`, und die Unschärfe trägt bewusst das meiste.
struct Bereichseintritt: ViewModifier {
    var unschaerfe: CGFloat
    var staerke: Double
    var groesse: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: unschaerfe)
            .opacity(staerke)
            .scaleEffect(groesse)
    }
}

extension AnyTransition {
    /// Der Wechsel in der Leiste — siehe die Zahlen in `Stil`.
    ///
    /// Berechnet statt abgelegt: `AnyTransition` ist nicht `Sendable`, eine
    /// gespeicherte Eigenschaft wäre unter Swift 6 ein gemeinsam genutzter
    /// veränderlicher Zustand.
    static var bereichswechsel: AnyTransition { .asymmetric(
        insertion: .modifier(
            active: Bereichseintritt(unschaerfe: Stil.bereichUnschaerfe,
                                     staerke: 0, groesse: Stil.bereichKleiner),
            identity: Bereichseintritt(unschaerfe: 0, staerke: 1, groesse: 1))
            .animation(Stil.zeitBereichHerein),
        removal: .opacity.animation(Stil.zeitBereichHinaus)) }
}
