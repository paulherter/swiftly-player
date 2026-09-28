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

import SwiftUI

extension Abspielwunsch {
    /// **Der eine Weg vom Tipp zum Player** fuer Film und Folge, auf iPhone
    /// und Fernseher.
    ///
    /// Er stand viermal da, wortgleich bis auf Kleinigkeiten: sperren, Plan
    /// holen, Wunsch bauen, entsperren. Wo er auseinanderlief, war es keine
    /// Absicht — die Serienseite des iPhones sagte nichts, wenn der Server
    /// keine Datei hatte, die des Fernsehers schon.
    ///
    /// - Parameters:
    ///   - ab: die Startstelle; ohne Angabe gilt die gemerkte des Titels.
    ///   - frisch: den Titel vorher neu holen — die Stelle im Listeneintrag
    ///     ist oft veraltet.
    ///   - bereitet: sperrt einen zweiten Tipp, solange der Plan unterwegs ist.
    ///   - fehlt: wenn der Server keinen Plan liefert.
    @MainActor
    static func starten(_ item: Item, ab: Double? = nil, frisch: Bool = false,
                        model: AppModel, bereitet: Binding<Bool>,
                        fehlt: @escaping () -> Void = {},
                        abspielen: @escaping (Abspielwunsch) -> Void) {
        guard !bereitet.wrappedValue else { return }
        bereitet.wrappedValue = true
        Task {
            defer { bereitet.wrappedValue = false }
            let ziel = frisch ? (await model.item(id: item.id) ?? item) : item
            guard let plan = await model.plan(for: ziel.id) else { fehlt(); return }
            abspielen(Abspielwunsch(item: ziel, plan: plan,
                                    startAt: ab ?? ziel.fortsetzenAb ?? 0))
        }
    }
}
