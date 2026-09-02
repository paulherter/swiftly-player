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
    static let ampelHoehe: CGFloat = 40

    /// Oberer Rand im **Inhaltsbereich**.
    ///
    /// Hier gibt es nichts freizuhalten: der Inhalt beginnt rechts der
    /// Seitenleiste, die Ampel liegt gar nicht darüber. Vorher standen hier
    /// dieselben 52 wie links — Platz für etwas, das dort nie war.
    static let inhaltOben: CGFloat = 52

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

    /// Überblenden beim Ersetzen. 180 ms ease-out — dieselbe Zeit, in der auf
    /// dem iPhone die Player-Steuerung erscheint.
    static let zeitSeite = Animation.easeOut(duration: 0.18)

    /// Das Schieben beim Tiefergehen.
    ///
    /// **Nachgemessen, nicht geschätzt.** `Fahrtmesser` schreibt den
    /// Zwischenwert jedes Einzelbildes mit; damit ist der Verlauf nachlesbar
    /// statt Geschmackssache.
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
