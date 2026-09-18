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
/// Gemessen: die leere Seite stand 92 bis 174 ms, und im mitgeschriebenen
/// Verlauf lag genau dort der Zeitsprung — der Moment, in dem die halbe Seite
/// auf einmal gebaut wurde.
///
/// Die Startseite weiß aber schon beim Laden, welche Serien in Frage kommen.
/// Also holt sie sie im Hintergrund, und der Klick findet sie vor.
/// **Und was einmal geholt wurde, bleibt für den Rückweg liegen.**
///
/// Wörtlich der `Serienspeicher` der tvOS-Fassung
/// (`Sources/tvOS/SerienView.swift`) — dort steht auch die Begründung, und
/// sie stammt von Paul: „die Seite lädt jetzt total immer, anstatt instant
/// smooth reinzukommen."
///
/// Der Abruf ist nicht langsam, er war nur verdeckt, solange der
/// Seitenwechsel überblendete. Die Antwort ist nicht, die Überblendung
/// zurückzuholen, sondern beim zweiten Mal gar nicht erst zu warten. Das
/// erklärt genau, warum es **beim ersten** Öffnen auffällt und danach nicht.
///
/// Absichtlich nur fürs Bild, nicht als Wahrheit: beim Erscheinen läuft der
/// Abruf trotzdem und schreibt frische Werte darüber.
@MainActor
@Observable
final class Seriencache {
    static let geteilt = Seriencache()

    struct Stand {
        var serie: Item?
        var staffeln: [Item] = []
        /// Je Staffel. Der Schlüssel ist die Staffel-ID.
        var folgen: [String: [Item]] = [:]
    }

    private var bekannt: [String: Item] = [:]
    private var staende: [String: Stand] = [:]
    private var reihenfolge: [String] = []
    private var laufend: Set<String> = []

    func serie(fuer folge: Item) -> Item? {
        folge.seriesId.flatMap { bekannt[$0] }
    }

    func merken(_ serie: Item) { bekannt[serie.id] = serie }

    func stand(_ serie: String) -> Stand? { staende[serie] }

    func merken(_ serie: String, _ aendern: (inout Stand) -> Void) {
        if staende[serie] == nil {
            staende[serie] = Stand()
            reihenfolge.append(serie)
        }
        aendern(&staende[serie]!)
        while reihenfolge.count > 12 { staende[reihenfolge.removeFirst()] = nil }
    }

    /// Holt die Serie zu **einer** Folge — für das Überfahren einer Kachel.
    ///
    /// Auf dem Mac liegt der Zeiger immer erst auf der Kachel, bevor geklickt
    /// wird; typisch ein paar Zehntelsekunden. Das reicht für den Abruf, und
    /// damit ist die leere Seite auch auf Wegen weg, die kein Vorholen der
    /// Reihe abdeckt — Suche, Ähnliches, ein frisch geöffnetes Fenster. Ein
    /// Grund, der mit der Eingabeart zu tun hat: iPhone und Fernseher haben
    /// dieses Zeitfenster nicht.
    func vorholen(_ folge: Item, mit model: AppModel) {
        guard folge.type == "Episode" else { return }
        vorholen([folge], mit: model)
    }

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
