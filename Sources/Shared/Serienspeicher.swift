import JellyfinKit
import SwiftUI

/// Serien, die zu einer Folge gehören — **vorgeholt, bevor jemand klickt.**
///
/// Auf der Startseite sind „Weiterschauen" und „Nächste Folge" Folgen, keine
/// Serien. Ein Druck darauf führt über `StaffelZiel` auf die Serienseite, und
/// die braucht erst einmal die Serie selbst. Bis sie da war, fuhr eine **leere
/// Seite** herein und die fertige erschien mit einem Schlag mittendrin.
///
/// Gemessen auf dem Mac: die leere Seite stand 92 bis 174 ms, und genau dort
/// lag im mitgeschriebenen Verlauf der Zeitsprung. Der Abruf ist nicht langsam
/// — er war nur verdeckt, solange der Seitenwechsel überblendete. Die Antwort
/// ist nicht, die Überblendung zurückzuholen, sondern beim zweiten Mal gar
/// nicht erst zu warten. Das erklärt auch, warum es **beim ersten** Öffnen
/// auffällt und danach nicht.
///
/// **Warum diese Datei geteilt ist, und warum das eine Behebung ist.** Es gab
/// sie zweimal: als `Serienspeicher` in `Sources/tvOS/SerienView.swift` und
/// als `Seriencache` in `Sources/macOS/Seriencache.swift` — die zweite mit dem
/// Kommentar „wörtlich der `Serienspeicher` der tvOS-Fassung". Zwei Kopien
/// derselben Regel, und iPhone und iPad hatten sie gar nicht: dort wartet die
/// Serienseite bis heute bei **jedem** Öffnen auf den Server. Genau die Sorte
/// Auseinanderlaufen, gegen die die Regel „eine kopierte Funktion ist ein
/// Fehler" steht.
///
/// **Absichtlich nur fürs Bild, nicht als Wahrheit.** Beim Erscheinen läuft
/// der Abruf trotzdem und schreibt frische Werte darüber. Was hier liegt, darf
/// veraltet sein; es darf nur nicht falsch aussehen.
@MainActor
@Observable
final class Serienspeicher {
    static let geteilt = Serienspeicher()

    struct Stand {
        /// Die Serie selbst — für den Umweg von einer Folge aus, der sie
        /// sonst jedes Mal nachholt. Siehe `StaffelZiel`.
        var serie: Item?
        var staffeln: [Item] = []
        /// Die Folge, mit der es weitergeht. Nur der Fernseher zeigt sie
        /// bisher an; sie steht hier, weil sie zum selben Stand gehört.
        var weiterMit: Item?
        /// Je Staffel. Der Schlüssel ist die Staffel-ID.
        var folgen: [String: [Item]] = [:]
    }

    /// Serien nach ihrer eigenen Kennung — für `serie(fuer:)`.
    private var bekannt: [String: Item] = [:]
    private var staende: [String: Stand] = [:]
    private var reihenfolge: [String] = []
    /// Läuft schon ein Abruf? Ohne das holt eine Reihe mit acht Folgen
    /// derselben Serie sie achtmal.
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
        // Zwölf reichen für den Rückweg und halten den Speicher klein.
        while reihenfolge.count > 12 { staende[reihenfolge.removeFirst()] = nil }
    }

    /// Holt die Serie zu **einer** Folge — für das Überfahren einer Kachel.
    ///
    /// **Das ist der eine Teil, der von der Eingabeart abhängt.** Auf dem Mac
    /// liegt der Zeiger immer erst auf der Kachel, bevor geklickt wird;
    /// typisch ein paar Zehntelsekunden, und das reicht für den Abruf. Damit
    /// ist die leere Seite auch auf Wegen weg, die kein Vorholen der Reihe
    /// abdeckt — Suche, Ähnliches, ein frisch geöffnetes Fenster. iPhone und
    /// Fernseher haben dieses Zeitfenster nicht; dort trägt nur das Vorholen
    /// der ganzen Reihe.
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

    /// Beim Kontowechsel gehört alles weg.
    ///
    /// Was hier liegt, gehört dem Konto, das es geholt hat — Titel, die das
    /// nächste womöglich gar nicht sehen darf. `AppModel.nachDemWechsel()`
    /// ruft das; ohne diese Zeile stünde nach dem Umschalten die Serie des
    /// vorigen Kontos sofort und ohne Abruf da.
    func leeren() {
        bekannt.removeAll()
        staende.removeAll()
        reihenfolge.removeAll()
        laufend.removeAll()
    }
}
