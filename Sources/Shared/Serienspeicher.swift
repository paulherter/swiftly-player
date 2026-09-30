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

    func serie(fuer folge: Item, mit model: AppModel) -> Item? {
        guard gueltig(model) else { return nil }
        return folge.seriesId.flatMap { bekannt[$0] }
    }

    func merken(_ serie: Item) { bekannt[serie.id] = serie }

    func stand(_ serie: String, mit model: AppModel) -> Stand? {
        guard gueltig(model) else { return nil }
        return staende[serie]
    }

    func merken(_ serie: String, _ aendern: (inout Stand) -> Void) {
        if staende[serie] == nil {
            staende[serie] = Stand()
            reihenfolge.append(serie)
        }
        aendern(&staende[serie]!)
        // Zwölf reichen für den Rückweg und halten den Speicher klein.
        while reihenfolge.count > 12 { staende[reihenfolge.removeFirst()] = nil }
    }

    /// **Was hier liegt, ist ab jetzt falsch.**
    ///
    /// Der Speicher hält die Folgen einer Serie samt `userData` — also samt
    /// Haken und Fortschritt. Er läuft nicht ab; geleert wird er nur beim
    /// Kontowechsel. Wer eine Folge als gesehen markiert, ändert den Stand
    /// beim Server, und was hier liegt, weiß nichts davon.
    ///
    /// Genau das ist am 12.09.2026 gemeldet worden: eine ganze Staffel Folge
    /// für Folge abgehakt, zurück, wieder hinein — alles wieder ungesehen.
    /// Der Server hatte jeden Haken; die Staffelansicht schrieb ihre frisch
    /// geholten Folgen nur nicht zurück, und die Serienseite setzt sich aus
    /// dem Speicher zusammen.
    ///
    /// **Wegwerfen statt nachtragen.** Den Haken im gemerkten `Item` zu
    /// ändern hieße, `Item` und `UserItemData` neu zu bauen, an einer Stelle,
    /// die davon nichts wissen sollte — und beim nächsten Feld stünde
    /// dieselbe Frage wieder. Der Speicher ist dafür da, dass der Rückweg
    /// nicht leer ist, nicht dafür, die Wahrheit über den Sehstand zu halten.
    func vergessen(_ serie: String) {
        staende[serie] = nil
        reihenfolge.removeAll { $0 == serie }
        bekannt[serie] = nil
    }

    /// **Der Stand ist nach dem Abspielen alt, die Folgen nicht.**
    ///
    /// `weiterMit` nennt der Hauptknopf der Serienseite beim Oeffnen, bevor
    /// der frische Stand da ist. Wer seitdem geschaut hat — etwa ueber
    /// „Weiterschauen" auf der Startseite, ohne die Serienseite —, bekam
    /// dort die alte Folge genannt und eine Sekunde spaeter die richtige.
    /// Der Knopf nennt nie eine geratene Folge; also weg damit, und die
    /// Seite zeigt bis zum Abruf ein neutrales „Abspielen".
    ///
    /// **Und die gemerkten Folgen mit** — samt Haken und Balken sind sie nach
    /// dem Abspielen genauso alt; wer aus „Weiterschauen" schaute und die Serie
    /// danach öffnete, sah zuerst den alten Stand, der eine Wimpernschlag
    /// später umsprang. Die Staffelliste ändert sich nicht und bleibt.
    func standVergessen(_ serie: String) {
        staende[serie]?.weiterMit = nil
        staende[serie]?.folgen = [:]
        naechste[serie] = nil
    }

    // MARK: Die naechste Folge, vor dem Klick

    /// **Wo es in einer Serie weitergeht — gemerkt, bevor jemand drueckt.**
    ///
    /// Getrennt von `staende`: die halten zwoelf Serien samt Folgenlisten,
    /// hier liegt nur je Serie eine Folge, fuer jede Serie der Startseite.
    /// Gefuellt aus „Weiterschauen" und „Naechste Folge" (dort *ist* die
    /// Kachel die Folge, vom Server so geliefert), aus dem Fokus auf einer
    /// Serien- oder Folgenkachel (`naechsteVorladen`) und aus dem Abruf der
    /// Serienseite selbst. Nach dem Abspielen verworfen (`standVergessen`).
    private var naechste: [String: Item] = [:]
    private var naechsteLaufend: Set<String> = []

    /// Die Folge, bei der es weitergeht, sofern bekannt — frischer Vorrat
    /// zuerst, dann der Stand der zuletzt besuchten Serienseite.
    func naechsteFolge(_ serie: String, mit model: AppModel) -> Item? {
        guard gueltig(model) else { return nil }
        return naechste[serie] ?? staende[serie]?.weiterMit
    }

    func naechsteMerken(_ folge: Item?, fuer serie: String) {
        naechste[serie] = folge
    }

    /// Aus einer Reihe der Startseite: jede Folge ist die, bei der es in
    /// ihrer Serie weitergeht.
    func naechsteMerken(aus reihe: [Item]) {
        for folge in reihe where folge.type == "Episode" {
            if let serie = folge.seriesId { naechste[serie] = folge }
        }
    }

    /// Holt den Stand der Serie zu dieser Kachel, falls er fehlt — gerufen,
    /// wenn eine Kachel den Fokus haelt (entprellt in `KachelStil`).
    func naechsteVorladen(zu titel: Item, mit model: AppModel) async {
        let serie: String? = switch titel.type {
        case "Series": titel.id
        case "Episode": titel.seriesId
        default: nil
        }
        guard let serie, gueltig(model), naechste[serie] == nil,
              staende[serie]?.weiterMit == nil,
              !naechsteLaufend.contains(serie),
              let client = model.client else { return }
        let konto = model.kontowechsel
        naechsteLaufend.insert(serie)
        defer { naechsteLaufend.remove(serie) }
        let folge = await client.standInSerie(serie)
        guard konto == model.kontowechsel, let folge else { return }
        naechste[serie] = folge
    }

    /// **Die Serien einer ganzen Reihe in einer Anfrage** — fuer die
    /// Angabenzeile der Startseite auf dem Fernseher.
    ///
    /// Dort steht bei einer Folge die Zeile der Serie (Jahr, Laufzeit,
    /// Sterne, Freigabe). Einzeln unter dem Fokus geholt kam sie einen
    /// Moment nach allem anderen. cb6bcefd hatte das Vorholen auf dem
    /// Fernseher abgeschaltet, weil es **18 Einzelabrufe** gleichzeitig mit
    /// den ersten Plakaten waren, deren Ergebnis niemand las. Beides ist
    /// jetzt anders: **eine** Anfrage `Items?Ids=…` je Reihe, erst nach dem
    /// Laden der Reihen, mit niedriger Prioritaet — und die Zeile liest es.
    func vorholenGebuendelt(_ folgen: [Item], mit model: AppModel) async {
        _ = gueltig(model)
        let offen = Array(Set(folgen.filter { $0.type == "Episode" }.compactMap(\.seriesId))
            .subtracting(bekannt.keys)
            .subtracting(laufend))
        guard !offen.isEmpty, let client = model.client else { return }
        let konto = model.kontowechsel
        laufend.formUnion(offen)
        defer { laufend.subtract(offen) }
        guard let antwort = try? await client.items(limit: offen.count, ids: offen),
              // Inzwischen ein anderes Konto: dessen Speicher, nicht dieser.
              konto == model.kontowechsel
        else { return }
        for serie in antwort.items { bekannt[serie.id] = serie }
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
        _ = gueltig(model)
        let offen = Set(folgen.compactMap(\.seriesId))
            .subtracting(bekannt.keys)
            .subtracting(laufend)
        guard !offen.isEmpty else { return }
        laufend.formUnion(offen)
        let konto = model.kontowechsel

        for id in offen {
            Task { @MainActor in
                let serie = await model.item(id: id)
                // Inzwischen ein anderes Konto: die Antwort trägt dessen
                // Vorgänger-Sehstand und gehört nicht in den neuen Speicher
                // (`gueltig` hat `laufend` dann schon geleert).
                if konto == model.kontowechsel {
                    if let serie { bekannt[id] = serie }
                    laufend.remove(id)
                }
            }
        }
    }

    /// Zu welchem Kontostand gehört, was hier liegt.
    ///
    /// **Der Speicher fragt selbst, statt dass jede Ansicht ans Räumen denken
    /// muss.** Das ist der Unterschied zu einem `leeren()`, das irgendwer
    /// rufen müsste: hier kann es niemand vergessen, weil jeder Zugriff
    /// ohnehin durch `stand(_:)` oder `serie(fuer:)` geht.
    ///
    /// **Und der Schaden steckt nicht in den Titeln, sondern im Sehstand.**
    /// Ein zwischengespeichertes `Item` trägt `userData` mit `played` und
    /// `playbackPositionTicks` — also den Stand des Kontos, das es geholt
    /// hat. Ohne diese Prüfung sähe man nach einem Wechsel auf einer Seite
    /// aus dem Speicher fremde Haken und fremde Fortschrittsbalken, und
    /// „Weiterschauen" setzte an fremder Stelle an und meldete sie dem neuen
    /// Konto. Von der Mac-Sitzung am Quelltext gefunden, bevor es jemandem
    /// auffiel.
    private var fuerKonto = 0

    /// Gehört der Inhalt noch zum angemeldeten Konto? Wenn nicht, wird er
    /// hier und jetzt verworfen.
    private func gueltig(_ model: AppModel) -> Bool {
        guard fuerKonto != model.kontowechsel else { return true }
        fuerKonto = model.kontowechsel
        bekannt.removeAll()
        staende.removeAll()
        naechste.removeAll()
        naechsteLaufend.removeAll()
        reihenfolge.removeAll()
        laufend.removeAll()
        return false
    }
}
