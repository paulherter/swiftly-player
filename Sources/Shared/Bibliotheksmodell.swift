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

    /// **Sortierung und Filter ueberleben den Neustart.**
    ///
    /// Ein Nutzer am 07.09.2026: „ich sortiere nach zuletzt, weil es
    /// praktisch ist. Verlasse ich die App und komme wieder, bin ich zurueck
    /// beim Standard." Er hat recht, und es ist keine Kleinigkeit: eine
    /// Sortierung ist keine Handlung, sondern eine Einstellung — man trifft
    /// sie einmal und erwartet sie danach vorzufinden.
    ///
    /// Gemerkt wird **je Ort**, nicht global: Filme nach Jahr und Serien
    /// nach zuletzt hinzugefuegt ist eine sinnvolle Kombination, und ein
    /// gemeinsamer Wert wuerde sie gegeneinander ausspielen. `merkname`
    /// unterscheidet sie; ohne Namen wird nichts gemerkt.
    var sortierung: Sortierung = .name { didSet { sichern() } }
    var filter: Bibliotheksfilter = .alle { didSet { sichern() } }

    /// Unter welchem Namen die beiden liegenbleiben — `nil` heisst: gar nicht.
    private let merkname: String?

    init(merkname: String? = nil) {
        self.merkname = merkname
        guard let merkname else { return }
        let ablage = UserDefaults.standard
        if let roh = ablage.string(forKey: "sortierung.\(merkname)"),
           let wert = Sortierung(rawValue: roh) { sortierung = wert }
        if let roh = ablage.string(forKey: "filter.\(merkname)"),
           let wert = Bibliotheksfilter(rawValue: roh) { filter = wert }
    }

    private func sichern() {
        guard let merkname else { return }
        let ablage = UserDefaults.standard
        ablage.set(sortierung.rawValue, forKey: "sortierung.\(merkname)")
        ablage.set(filter.rawValue, forKey: "filter.\(merkname)")
    }

    /// Wechselt eines davon, wird neu geladen.
    var kennung: String { "\(sortierung.rawValue)|\(filter.rawValue)" }

    /// Ob es hinter dem, was schon dasteht, noch etwas gibt.
    var nochMehrDa: Bool {
        sieb == nil ? Listenregeln.nochMehrDa(geladen: items.count, gesamt: gesamt)
                    : Listenregeln.nochMehrDa(geladen: rohVersatz, gesamt: rohGesamt)
    }

    /// **Aus mehreren Bibliotheken wird gesiebt** (``Titelsieb``). Dann
    /// blättert die Seite in der Antwort des Servers, nicht in dem, was
    /// stehen blieb: `rohVersatz` ist, wie weit der Server schon geliefert
    /// hat, `rohGesamt`, wie viel er hat.
    private var sieb: Titelsieb?
    private var rohVersatz = 0
    private var rohGesamt = 0

    /// Ob diese Kachel das Nachladen auslöst — jede der letzten drei Reihen,
    /// siehe `Listenregeln.imNachladebereich`.
    func loestNachladenAus(_ id: String, spalten: Int) -> Bool {
        Listenregeln.imNachladebereich(id, in: items, spalten: spalten)
    }

    /// Wofür `items` geladen wurden: Bibliothek, Sortierung, Filter, Konto.
    /// Gleich heißt: nur auffrischen. Anders heißt: ersetzen.
    private var geladenFuer: String?

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
        let bib = await quelle(model, art: art, bibliothek: bibliothek)
        await laden(model, aus: bib.map { Regalquelle(eltern: $0.id, art: art ?? $0.collectionType) })
    }

    /// Dasselbe mit fertiger Quelle — „Alle" quer über die Bibliotheken oder
    /// eine Sammlung. `nil` heißt: in diesem Bereich gibt es nichts.
    func laden(_ model: AppModel, aus quelle: Regalquelle?) async {
        laedt = items.isEmpty
        gestoert = false
        fuerKonto = model.kontowechsel
        guard let quelle else {
            // Zwei Faelle sehen hier gleich aus: ein Server ohne Bibliothek
            // dieser Gattung, und einer, der gar nicht geantwortet hat.
            // Unterscheidbar daran, ob ueberhaupt Bibliotheken bekannt sind.
            gestoert = model.views.isEmpty
            laedt = false
            return
        }
        if quelle.siebt {
            await gesiebtLaden(model, aus: quelle)
            laedt = false
            return
        }
        sieb = nil
        if let seite = await model.items(aus: quelle, sortierung: sortierung,
                                         filter: filter, ab: 0) {
            // Beim Zurückkommen von einer Detailseite läuft das hier erneut —
            // und darf nicht auf die erste Seite kürzen, siehe `auffrischen`.
            let fuer = "\(quelle.schluessel)|\(kennung)|\(fuerKonto)"
            items = geladenFuer == fuer
                ? Listenregeln.auffrischen(seite.titel, in: items,
                                           gesamtVorher: gesamt, gesamtJetzt: seite.gesamt)
                : Listenregeln.ohneDoppelte(seite.titel)
            geladenFuer = fuer
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
        guard !veraltet(model), nochMehrDa, !laedtNach, !laedt else { return }
        guard let bib = await quelle(model, art: art, bibliothek: bibliothek) else { return }
        await nachladen(model, aus: Regalquelle(eltern: bib.id, art: art ?? bib.collectionType))
    }

    func nachladen(_ model: AppModel, aus quelle: Regalquelle) async {
        // **Nach einem Kontowechsel wird nicht angehängt.** Was dasteht,
        // gehört dem vorigen Konto; die zweite Seite käme vom neuen, und
        // beides zusammen ergäbe eine Sammlung, die es nirgends gibt. Wer
        // nachlädt, ohne vorher neu geladen zu haben, bekommt hier nichts.
        guard !veraltet(model) else { return }
        guard nochMehrDa, !laedtNach, !laedt else { return }
        // Vor dem ersten `await` gesperrt: sonst kommen zwei Kacheln des
        // Nachladebereichs gleichzeitig durch.
        laedtNach = true
        defer { laedtNach = false }
        let vorher = geladenFuer
        if quelle.siebt, var s = sieb {
            guard let (neu, versatz, roh) = await fuellen(model, aus: quelle, sieb: &s,
                                                          ab: rohVersatz, erste: AppModel.seitengroesse),
                  geladenFuer == vorher else { return }
            sieb = s
            items = Listenregeln.anhaengen(neu, an: items)
            rohVersatz = versatz
            rohGesamt = roh
            return
        }
        guard let seite = await model.items(aus: quelle, sortierung: sortierung,
                                            filter: filter, ab: items.count)
        else { return }
        // Wurde inzwischen umsortiert oder gefiltert, gehört die Seite zu
        // einer anderen Liste.
        guard geladenFuer == vorher else { return }
        items = Listenregeln.anhaengen(seite.titel, an: items)
        gesamt = seite.gesamt
    }

    // MARK: Gesiebt

    /// Erste Seite aus mehreren Bibliotheken. Beim Zurückkommen von einer
    /// Detailseite wird so weit neu geholt, wie schon geblättert war — in
    /// einem Zug, damit die Liste nicht auf die erste Seite schrumpft und der
    /// Fortschritt der Kacheln trotzdem frisch ist.
    private func gesiebtLaden(_ model: AppModel, aus quelle: Regalquelle) async {
        let fuer = "\(quelle.schluessel)|\(kennung)|\(fuerKonto)"
        guard var neuesSieb = await model.titelsieb(quelle, filter: filter) else {
            if !Task.isCancelled { gestoert = items.isEmpty }
            return
        }
        let erste = max(AppModel.seitengroesse, geladenFuer == fuer ? rohVersatz : 0)
        guard let (neu, versatz, roh) = await fuellen(model, aus: quelle, sieb: &neuesSieb,
                                                      ab: 0, erste: erste) else {
            if !Task.isCancelled { gestoert = items.isEmpty }
            return
        }
        sieb = neuesSieb
        items = neu
        rohVersatz = versatz
        rohGesamt = roh
        gesamt = neuesSieb.gesamt
        geladenFuer = fuer
    }

    /// Holt Seiten, bis etwas stehen bleibt. Eine Seite kann fast ganz aus
    /// Doppeln bestehen — dann erschiene keine neue Kachel, an der das
    /// nächste Nachladen hängen könnte, und die Liste bliebe stehen.
    private func fuellen(_ model: AppModel, aus quelle: Regalquelle, sieb: inout Titelsieb,
                         ab start: Int, erste: Int) async -> ([Item], Int, Int)? {
        var neu: [Item] = []
        var versatz = start
        var roh = 0
        var anzahl = erste
        repeat {
            guard let seite = await model.items(aus: quelle, sortierung: sortierung,
                                                filter: filter, ab: versatz, anzahl: anzahl)
            else { return nil }
            neu += sieb.sieben(seite.titel)
            versatz += seite.titel.count
            roh = seite.gesamt
            anzahl = AppModel.seitengroesse
            if seite.titel.isEmpty { break }
        } while neu.count < AppModel.seitengroesse / 2 && versatz < roh
        return (neu, versatz, roh)
    }
}
