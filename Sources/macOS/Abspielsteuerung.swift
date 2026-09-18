import JellyfinKit
import Observation
import SwiftUI

/// Wer den Player öffnet.
///
/// Auf dem iPhone hängt der Player als `fullScreenCover` an der Seite, von der
/// aus gestartet wurde. Im Fenster geht das nicht: der Player soll das **ganze**
/// Fenster einnehmen, Seitenleiste eingeschlossen. Also liegt der Wunsch eine
/// Ebene höher, bei `HauptView`, und die Seiten melden ihn nur an.
///
/// Der `Abspielwunsch` selbst ist der geteilte Typ aus `Sources/Shared` —
/// Titel, Plan und Startposition gemeinsam, aus demselben Grund wie dort.
@MainActor
@Observable
final class Abspielsteuerung {
    var wunsch: Abspielwunsch?
    /// Steht hier, wenn der Server die Wiedergabe verweigert. Fehler stehen
    /// dort, wo sie entstehen — kein Hinweisfenster.
    var fehler: String?

    private let model: AppModel

    init(model: AppModel) { self.model = model }

    /// Startet dort, wo der Server sagt: angefangenes an seiner Position,
    /// sonst von vorn. Wörtlich die Regel der iPhone-Fassung.
    func starte(_ item: Item, ab: Double? = nil) {
        Task {
            // **Die Stelle frisch holen, wenn keine vorgegeben ist** (Audit
            // 16.09., T2-M5). Die aus der Kachel kann alt sein: auf dem Handy
            // weitergeschaut, am Mac geklickt, bevor die Startseite neu lud —
            // und der Film begann an der alten Stelle. iOS und tvOS holen sie
            // schon so; hier nebenher zum Plan, damit es nicht länger dauert.
            async let frisch = ab == nil ? model.item(id: item.id) : nil
            guard let plan = await model.plan(for: item.id) else {
                // Der Fehler nennt den Server, nicht nur „ging nicht" — sonst
                // weiß man bei mehreren Servern nicht, welcher gemeint ist.
                let wo = model.serverName ?? String(localized: "dem Server")
                fehler = String(localized: "Die Wiedergabe hat nicht geklappt — \(wo) hat keinen Plan geliefert.")
                return
            }
            let frischer = await frisch
            let stelle = ab ?? (frischer ?? item).fortsetzenAb ?? 0
            wunsch = Abspielwunsch(item: item, plan: plan, startAt: stelle)
        }
    }

    func schliessen() { wunsch = nil }
}
