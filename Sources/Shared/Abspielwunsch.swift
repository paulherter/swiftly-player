import Foundation
import JellyfinKit

/// Trägt Titel, Plan und Startposition gemeinsam zum Player.
///
/// Bewusst als ein Objekt: getrennte Zustände liest `fullScreenCover` beim
/// Präsentieren noch im alten Stand, wodurch der Player bei null startete.
/// Auf tvOS gilt dasselbe für `fullScreenCover` dort.
struct Abspielwunsch: Identifiable {
    let id = UUID()
    let item: Item
    let plan: PlaybackPlan
    let startAt: Double
}
