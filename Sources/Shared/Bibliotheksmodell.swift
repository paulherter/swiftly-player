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

    /// Zu welchem Konto gehört, was hier steht.
    ///
    /// **Das Regal überlebt den Kontowechsel, die Ansicht darüber nicht
    /// unbedingt.** Auf dem Mac hängt `BibliothekView` an `.task(id:)` mit
    /// Sortierung und Filter — beim Wechsel ändert sich davon nichts, also
    /// lud niemand neu, und die Sammlung des vorigen Kontos stand bis zum
    /// Neustart da. Von der Mac-Sitzung gefunden und dort in der Ansicht
    /// behoben; hier steht die Hälfte, die alle Plattformen teilen.
    private var fuerKonto = 0

    /// Gehört, was hier steht, noch zum angemeldeten Konto?
    ///
    /// Die Antwort ist für jede Plattform dieselbe, das Nachladen nicht: auf
    /// Apple hängt eine Ansicht an `.task(id:)`, auf Linux und Windows gibt
    /// es kein `onChange` und der Zähler wird von Hand verglichen. Deshalb
    /// steht hier die Frage und nicht der Auslöser.
    func veraltet(_ model: AppModel) -> Bool { fuerKonto != model.kontowechsel }

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
    ///
    /// **Nicht mehr `views.first`.** Hat der Server zwei Bibliotheken
    /// derselben Gattung, war die zweite damit unerreichbar. Jetzt gilt die
    /// gemerkte Wahl, und die erste ist nur noch der Rückfall.
    private func quelle(_ model: AppModel, art: String?, bibliothek: Item?) async -> Item? {
        if let bibliothek { return bibliothek }
        if model.views.isEmpty { await model.loadViews() }
        guard let art else { return nil }
        return model.gewaehlteBibliothek(art: art)
    }

    func laden(_ model: AppModel, art: String? = nil, bibliothek: Item? = nil) async {
        laedt = items.isEmpty
        gestoert = false
        fuerKonto = model.kontowechsel
        guard let bib = await quelle(model, art: art, bibliothek: bibliothek) else {
            // Zwei Faelle sehen hier gleich aus: ein Server ohne Bibliothek
            // dieser Gattung, und einer, der gar nicht geantwortet hat.
            // Unterscheidbar daran, ob ueberhaupt Bibliotheken bekannt sind.
            gestoert = model.views.isEmpty
            laedt = false
            return
        }
        if let seite = await model.items(in: bib.id, art: art ?? bib.collectionType,
                                         sortierung: sortierung,
                                         filter: filter, ab: 0) {
            items = seite.titel
            gesamt = seite.gesamt
        } else if !Task.isCancelled {
            // Steht schon etwas da, bleibt es stehen — was geladen war, ist
            // nicht falsch geworden, nur weil der Nachschlag scheiterte.
            //
            // **Ein Abbruch ist kein Ausfall.** `.task(id:)` bricht die alte
            // Aufgabe ab, sobald sich die Kennung aendert; die laufende
            // Anfrage kommt dann als Fehlschlag zurueck und sah bis eben
            // aus wie ein stummer Server. Die Seite zeigte „Kein Kontakt zum
            // Server" ueber den Plakaten, die der Nachfolger gerade geladen
            // hatte.
            gestoert = items.isEmpty
        }
        laedt = false
    }

    func nachladen(_ model: AppModel, art: String? = nil, bibliothek: Item? = nil) async {
        // **Nach einem Kontowechsel wird nicht angehängt.** Was dasteht,
        // gehört dem vorigen Konto; die zweite Seite käme vom neuen, und
        // beides zusammen ergäbe eine Sammlung, die es nirgends gibt. Wer
        // nachlädt, ohne vorher neu geladen zu haben, bekommt hier nichts.
        guard !veraltet(model) else { return }
        guard nochMehrDa, !laedtNach, !laedt else { return }
        guard let bib = await quelle(model, art: art, bibliothek: bibliothek) else { return }
        laedtNach = true
        defer { laedtNach = false }
        guard let seite = await model.items(in: bib.id, art: art ?? bib.collectionType,
                                            sortierung: sortierung,
                                            filter: filter, ab: items.count)
        else { return }
        let bekannt = Set(items.map(\.id))
        items.append(contentsOf: seite.titel.filter { !bekannt.contains($0.id) })
        gesamt = seite.gesamt
    }
}
