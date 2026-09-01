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

    /// Die Fensterknöpfe des Systems sitzen oben links **in** unserem
    /// Fenster. Diese Höhe hält den Platz frei — die Wortmarke beginnt
    /// darunter, sonst läge sie unter den drei Punkten.
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

    /// Heldenbild auf den Detailseiten. Höher als die 300 des iPhones, weil
    /// das Fenster breiter ist und ein flaches Band sonst gedrückt wirkt.
    static let heldHoehe: CGFloat = 420

    // MARK: Tippflächen — kleiner als auf dem iPhone

    /// Ein Zeiger trifft genauer als ein Finger. Apples eigene Seitenleisten
    /// stehen auf 28; 32 gibt der Schrift von 15 etwas mehr Luft.
    static let zeileHoehe: CGFloat = 32
    /// Runde Aktionsknöpfe auf den Detailseiten — auf dem iPhone 44.
    static let knopfRund: CGFloat = 40
    /// Der Hauptknopf bleibt 48 hoch, aber **nicht** über die volle Breite:
    /// ein Zeiger trifft einen Knopf, ein Daumen braucht die Fläche.
    static let hauptknopfHoehe: CGFloat = 48

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
}
