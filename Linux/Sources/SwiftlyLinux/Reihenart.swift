import Foundation
import JellyfinKit

/// Die drei Reihen der Startseite. Sie unterscheiden sich in mehr als der
/// Überschrift: Bild, Titel und Zweitzeile sind je Reihe andere — nachzulesen
/// in ``App/kachelBauen(_:art:)``.
enum Reihenart {
    case weiterschauen, naechste, neu
}

/// Eine Reihe der Startseite: Titel, Art, Titel darin und — bei einer
/// gewählten Bibliothek oder Sammlung — das Ziel, das der Kopf öffnet.
typealias Startreihenzeile = (String, Reihenart, [Item], Item?)
