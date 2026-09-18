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
            guard let plan = await model.plan(for: item.id) else {
                // Der Fehler nennt den Server, nicht nur „ging nicht" — sonst
                // weiß man bei mehreren Servern nicht, welcher gemeint ist.
                let wo = model.serverName ?? String(localized: "dem Server")
                fehler = String(localized: "Die Wiedergabe hat nicht geklappt — \(wo) hat keinen Plan geliefert.")
                return
            }
            wunsch = Abspielwunsch(item: item, plan: plan,
                                   startAt: ab ?? item.fortsetzenAb ?? 0)
        }
    }

    func schliessen() { wunsch = nil }
}
