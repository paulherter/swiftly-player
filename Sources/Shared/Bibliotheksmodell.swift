import Foundation
import JellyfinKit
import Observation

/// Eine Bibliothek mit Filter, Sortierung und Nachladen — für beide
/// Plattformen.
///
/// Auch das lag zweimal fast gleich vor, samt der Feinheit, die man beim
/// Nachbauen übersieht: der Server kann zwischen zwei Seiten etwas
/// hinzufügen, dann käme ein Titel doppelt und `ForEach` beschwert sich über
/// die doppelte Kennung.
@MainActor
@Observable
final class Bibliotheksmodell {
    private(set) var items: [Item] = []
    private(set) var gesamt = 0
    private(set) var laedt = true
    /// Der Server hat nicht geantwortet — im Unterschied zu „hier liegt
    /// nichts". Dieselbe Unterscheidung trifft `Startseitenmodell`; ohne sie
    /// meldete die Bibliothek einen ausgefallenen Server als leeres Regal.
    private(set) var gestoert = false
    private var laedtNach = false

    var sortierung: Sortierung = .name
    var filter: Bibliotheksfilter = .alle

    /// Wechselt eines davon, wird neu geladen.
    var kennung: String { "\(sortierung.rawValue)|\(filter.rawValue)" }

    /// Ob es hinter dem, was schon dasteht, noch etwas gibt.
    var nochMehrDa: Bool { items.count < gesamt }

    /// Ab welchem Eintrag nachgeladen wird — die drittletzte Reihe, damit der
    /// Nachschub steht, bevor man unten ankommt.
    func nachladenAb(spalten: Int) -> String? {
        guard !items.isEmpty else { return nil }
        return items[max(0, items.count - 3 * spalten)].id
    }

    /// Welche Bibliothek gemeint ist — genannt oder über die Gattung gesucht.
    private func quelle(_ model: AppModel, art: String?, bibliothek: Item?) async -> Item? {
        if let bibliothek { return bibliothek }
        if model.views.isEmpty { await model.loadViews() }
        return model.views.first { $0.collectionType == art }
    }

    func laden(_ model: AppModel, art: String? = nil, bibliothek: Item? = nil) async {
        laedt = items.isEmpty
        gestoert = false
        guard let bib = await quelle(model, art: art, bibliothek: bibliothek) else {
            // Zwei Faelle sehen hier gleich aus: ein Server ohne Bibliothek
            // dieser Gattung, und einer, der gar nicht geantwortet hat.
            // Unterscheidbar daran, ob ueberhaupt Bibliotheken bekannt sind.
            gestoert = model.views.isEmpty
            laedt = false
            return
        }
        if let seite = await model.items(in: bib.id, sortierung: sortierung,
                                         filter: filter, ab: 0) {
            items = seite.titel
            gesamt = seite.gesamt
        } else {
            // Steht schon etwas da, bleibt es stehen — was geladen war, ist
            // nicht falsch geworden, nur weil der Nachschlag scheiterte.
            gestoert = items.isEmpty
        }
        laedt = false
    }

    func nachladen(_ model: AppModel, art: String? = nil, bibliothek: Item? = nil) async {
        guard nochMehrDa, !laedtNach, !laedt else { return }
        guard let bib = await quelle(model, art: art, bibliothek: bibliothek) else { return }
        laedtNach = true
        defer { laedtNach = false }
        guard let seite = await model.items(in: bib.id, sortierung: sortierung,
                                            filter: filter, ab: items.count) else { return }
        let bekannt = Set(items.map(\.id))
        items.append(contentsOf: seite.titel.filter { !bekannt.contains($0.id) })
        gesamt = seite.gesamt
    }
}
