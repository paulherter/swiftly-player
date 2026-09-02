import JellyfinKit
import SwiftUI

/// Serien, die zu einer Folge gehören — **vorgeholt, bevor jemand klickt.**
///
/// Auf der Startseite sind „Weiterschauen" und „Nächste Folge" Folgen, keine
/// Serien. Ein Klick darauf führt über `StaffelZiel` auf die Serienseite
/// (A8), und das braucht erst einmal die Serie selbst. Bis sie da war, fuhr
/// eine **leere Seite** herein und die fertige erschien mit einem Schlag
/// mittendrin.
///
/// Gemessen: „StaffelZiel: leere Seite 69 ms lang", und im Fahrtschreiber ein
/// Zeitsprung von 32 ms bei Versatz 1025 — genau der Moment, in dem die halbe
/// Seite auf einmal gebaut wurde.
///
/// Die Startseite weiß aber schon beim Laden, welche Serien in Frage kommen.
/// Also holt sie sie im Hintergrund, und der Klick findet sie vor.
@MainActor
@Observable
final class Seriencache {
    static let geteilt = Seriencache()

    private var bekannt: [String: Item] = [:]
    private var laufend: Set<String> = []

    func serie(fuer folge: Item) -> Item? {
        folge.seriesId.flatMap { bekannt[$0] }
    }

    func merken(_ serie: Item) { bekannt[serie.id] = serie }

    /// Holt die Serien zu diesen Folgen, sofern noch nicht bekannt.
    func vorholen(_ folgen: [Item], mit model: AppModel) {
        let offen = Set(folgen.compactMap(\.seriesId))
            .subtracting(bekannt.keys)
            .subtracting(laufend)
        guard !offen.isEmpty else { return }
        laufend.formUnion(offen)

        for id in offen {
            Task { @MainActor in
                if let serie = await model.item(id: id) { bekannt[id] = serie }
                laufend.remove(id)
            }
        }
    }
}
