import JellyfinKit
import Observation
import SwiftUI

/// Der Seitenstapel je Bereich — **selbst geführt statt `NavigationStack`.**
///
/// Der Grund ist nicht Geschmack. `NavigationStack` hat auf dem Mac dreimal
/// etwas mitgebracht, das wir wieder abstellen mussten: einen Zurückpfeil in
/// der Fensterampel, einen Werkzeugleisten-Grund über dem Bild, und einen
/// Sicherheitsrand, der mal ankam und mal nicht. Was er dafür liefern sollte —
/// eine Bewegung beim Öffnen und Schließen — liefert er hier gar nicht.
///
/// Ein eigener Stapel ist ein Feld und zwei Methoden. Dafür gilt die Regel aus
/// `Stil` wörtlich: **tiefer gehen schiebt von rechts, zurück schiebt nach
/// rechts hinaus.**
@MainActor
@Observable
final class Navigator {
    /// Was auf welchem Bereich liegt. Wer zwischen Filmen und Serien
    /// wechselt, findet zurück, wo er war.
    private var stapel: [Bereich: [Seitenziel]] = [:]

    func seiten(_ bereich: Bereich) -> [Seitenziel] { stapel[bereich] ?? [] }

    func oeffne(_ ziel: Seitenziel, in bereich: Bereich) {
        // **Ohne Animation anlegen.** Die Seite soll erst dastehen und
        // ausgelegt sein; die Bewegung startet `HauptView` ein Einzelbild
        // später über `gezeigteTiefe`.
        // Liegt das Ziel schon im Stapel, gilt seine Kennung nur einmal:
        // dann zurück auf diese Seite statt zweimal anhängen.
        if let stelle = stapel[bereich]?.firstIndex(where: { $0.id == ziel.id }) {
            zurueck(in: bereich, bis: stelle + 1)
            return
        }
        stapel[bereich, default: []].append(ziel)
    }

    /// Alles weg — **G4**: ein Stapel gehört zu einem Konto.
    ///
    /// Ohne Anweisung von aussen wäre das ein Sprung; die Seiten fahren
    /// deshalb nach rechts hinaus wie beim Zurückgehen, nur alle auf einmal.
    /// Es bleibt bei **einer** Bewegung, weil `HauptView` den Mitgang im
    /// selben Zug zurückzieht.
    /// **Ausgenommen ist die Profilseite** — sie zeigt den Bund, nicht ein
    /// Konto, und sie ist die Seite, auf der gewechselt wird. Fiele sie mit,
    /// müsste man sie zwischen zwei Wechseln jedes Mal neu öffnen; der
    /// Streifen steht aber genau dafür da, mehrmals umzuschalten. Steht so
    /// in G4.
    func alleLeeren() {
        guard stapel.contains(where: { !$0.value.isEmpty }) else { return }
        withAnimation(Stil.zeitSeitenschub) {
            for (bereich, seiten) in stapel {
                // **`contains`, nicht `last`.** Wer vom Profil aus einen
                // Server hinzufuegt, steht beim Wechsel auf der
                // Aufnahmeseite — die faellt mit, das Profil darunter bleibt.
                // Mit `last` fiel es mit ihr, und man landete auf „Start",
                // ohne den Server zu sehen, den man gerade aufgenommen hat.
                stapel[bereich] = seiten.contains(.profil) ? [.profil] : []
            }
        }
    }

    /// **Alles weg, auch die Profilseite** — der Kontowechsel aus der
    /// Profilseite (Entwurf D, wie am iPhone): die Seite fährt wie beim
    /// Zurückgehen nach rechts hinaus, und das Profilbild fliegt in die
    /// Seitenleiste (``Kontowechselflug``). Die Ausnahme aus G4 gilt für
    /// jeden anderen Wechsel weiter — etwa die Anmeldung auf einem neuen
    /// Server, nach der man den Server im Profil sehen will.
    func allesLeeren() {
        guard stapel.contains(where: { !$0.value.isEmpty }) else { return }
        // Mit reduzierter Bewegung nur die Blende — wie das Standbild am
        // iPhone, das dann ausblendet statt wegzufahren.
        withAnimation(Stil.bewegungReduziert ? Stil.blendeReduziert : Stil.zeitSeitenschub) {
            for bereich in stapel.keys { stapel[bereich] = [] }
        }
    }

    /// **Die Pruefung gehoert in die Animation, nicht davor.**
    ///
    /// Sie stand davor, und die App stuerzte ab, sobald man einen zweiten
    /// Server hinzufuegte: die Anmeldung dort zaehlt `kontowechsel` hoch,
    /// `HauptView` raeumt darauf mit `alleLeeren()` alle Stapel — und
    /// SwiftUI arbeitet diese Beobachtung innerhalb von `withAnimation` ab.
    /// Zwischen dem `guard` und dem `removeLast` war der Stapel also leer,
    /// und `removeLast` auf einem leeren Feld ist kein Fehlschlag, sondern
    /// ein Abbruch.
    func zurueck(in bereich: Bereich) {
        withAnimation(Stil.zeitSeitenschub) {
            guard !(stapel[bereich] ?? []).isEmpty else { return }
            stapel[bereich]?.removeLast()
        }
    }

    /// **Zurueck, aber nur von genau dieser Seite.**
    ///
    /// Eine Unterseite, die sich selbst schliesst, weiss nicht, ob sie
    /// ueberhaupt noch liegt: eine Anmeldung raeumt den Stapel, ein
    /// Kontowechsel ebenso. Wer dann blind `zurueck` ruft, nimmt die Seite
    /// darunter mit — beim Server-Hinzufuegen war das die Profilseite, auf
    /// der man den neuen Server gerade sehen wollte.
    func schliessen(_ ziel: Seitenziel, in bereich: Bereich) {
        withAnimation(Stil.zeitSeitenschub) {
            guard stapel[bereich]?.last == ziel else { return }
            stapel[bereich]?.removeLast()
        }
    }

    /// Zurueck, bis noch `tiefe` Seiten liegen — in **einer** Bewegung.
    func zurueck(in bereich: Bereich, bis tiefe: Int) {
        withAnimation(Stil.zeitSeitenschub) {
            guard let seiten = stapel[bereich], seiten.count > tiefe else { return }
            stapel[bereich] = Array(seiten.prefix(tiefe))
        }
    }

    /// Liegt auf diesem Stapel der Kontozweig — siehe `Seitenziel.imKontozweig`?
    func imKonto(_ bereich: Bereich) -> Bool {
        seiten(bereich).contains { $0.imKontozweig }
    }

    /// Nimmt den Kontozweig vom Stapel; was darunter lag, bleibt liegen.
    ///
    /// Mit Bewegung ist das ein gewoehnliches Zurueck. Ohne, wenn der
    /// Bereich gerade nicht zu sehen ist oder seine Wurzel getauscht wird —
    /// dann muss `HauptView` die gezeigte Tiefe selbst nachziehen.
    func kontozweigSchliessen(in bereich: Bereich, animiert: Bool) {
        let seiten = seiten(bereich)
        guard let ab = seiten.firstIndex(where: { $0.imKontozweig }) else { return }
        if animiert {
            zurueck(in: bereich, bis: ab)
        } else {
            stapel[bereich] = Array(seiten.prefix(ab))
        }
    }
}

/// Wohin eine Seite führen kann.
///
/// Eigener Typ statt `any Hashable`: der Stapel muss vergleichbar sein, damit
/// SwiftUI den Wechsel als solchen erkennt — und ein Aufzählungstyp sagt beim
/// Lesen, welche Ziele es überhaupt gibt.
enum Seitenziel: Hashable, Identifiable {
    case titel(Item)
    /// **Eine Bibliothek als eigene Seite.**
    ///
    /// **Nicht mehr in Gebrauch.** Seit dem 23.09.2026 stehen die übrigen
    /// Bibliotheken im Titelmenü von Filme und Serien, nicht mehr in der
    /// Seitenleiste; der Fall bleibt nur stehen, damit ein alter,
    /// wiederhergestellter Stapel nicht bricht.
    case bibliothek(Item)
    /// **Eine Sammlung** — aus dem Titelmenü („Sammlungen") oder aus „Teil
    /// der Sammlung" auf der Filmseite. Anders als eine Bibliothek eine
    /// Unterseite mit Pfeil, wie auf dem iPhone. `art`: ihre Filme oder ihre
    /// Serien; `nil`: alles, was in ihr steht.
    case sammlung(Item, art: String?)
    /// **Eine geladene Serie** — aus den Downloads, ohne Server: alles kommt
    /// von der Platte.
    case downloadserie(String, titel: String)
    /// **Nicht mehr in Gebrauch.** Die Merkliste ist seit dem 06.09.2026 ein
    /// eigener Bereich in der Leiste; der Fall bleibt nur stehen, damit ein
    /// alter, wiederhergestellter Stapel nicht bricht.
    ///
    /// Vorher: eine Seite aus der
    /// Leiste. Auf dem iPhone haengt sie am Zeichen oben rechts.
    case merkliste
    /// Seerr anbinden — eine Zugabe, deshalb hinter den Einstellungen.
    case seerr
    /// Trakt verbinden — wie Seerr hinter den Einstellungen.
    case trakt
    /// Ein Titel, den der eigene Server nicht hat — aus der Suche.
    case seerrTitel(Seerrtreffer)
    /// Eine Person aus der Besetzung — was es von ihr gibt.
    case person(Person, herkunft: String?)
    /// Alle Titel eines Genres, aus den Chips der Startseite.
    case gattung(String)
    case profil
    case einstellungen
    case wiedergabe
    /// Wie die App aussieht und was auf der Startseite steht.
    case darstellung
    /// Ein Genre für die Startseite dazunehmen.
    case genrewahl
    case quickConnect
    case kontoHinzufuegen
    /// **Ein zweiter Jellyfin.** Mit Adresse, wenn das Konto auf einem
    /// Server angelegt wird, den es im Bund schon gibt — dann steht die
    /// Adresse fest und wird nur noch angezeigt.
    case serverHinzufuegen(URL?)

    var id: String {
        switch self {
        case let .titel(item):  "titel-\(item.id)"
        case let .bibliothek(b): "bibliothek-\(b.id)"
        case let .sammlung(s, art): "sammlung-\(s.id)-\(art ?? "")"
        case let .downloadserie(id, _): "downloadserie-\(id)"
        case .merkliste:        "merkliste"
        case .seerr:            "seerr"
        case .trakt:            "trakt"
        case let .seerrTitel(t): "seerr-\(t.art)-\(t.id)"
        case let .person(p, _): "person-\(p.id)"
        case let .gattung(name): "gattung-\(name)"
        case .profil:           "profil"
        case .einstellungen:    "einstellungen"
        case .wiedergabe:       "wiedergabe"
        case .darstellung:      "darstellung"
        case .genrewahl:        "genrewahl"
        case .quickConnect:     "quickconnect"
        case .kontoHinzufuegen: "kontohinzufuegen"
        case let .serverHinzufuegen(url): "serverneu-\(url?.absoluteString ?? "")"
        }
    }

    /// **Gehoert die Seite zum Konto statt zum Bereich?**
    ///
    /// Das Profil wird aus der Leiste geoeffnet und liegt auf dem Stapel des
    /// Bereichs, der gerade offen ist — gehoert aber zu keinem. Dasselbe gilt
    /// fuer alles, was von dort aus aufgeht. Solange so eine Seite liegt,
    /// traegt unten das Konto die Auswahl, und ein Klick auf einen Bereich
    /// nimmt sie wieder weg.
    var imKontozweig: Bool {
        switch self {
        case .profil, .einstellungen, .wiedergabe, .seerr, .trakt, .darstellung,
             .genrewahl, .quickConnect, .kontoHinzufuegen, .serverHinzufuegen: true
        // **Die Personenseite gehoert zum Bereich, nicht zum Konto.** Man
        // kommt aus einem Titel dorthin und will von dort weiter in den
        // naechsten — sie liegt im selben Zweig wie die Seite, die sie
        // geoeffnet hat. Dasselbe gilt fuer ein Genre.
        case .titel, .bibliothek, .sammlung, .downloadserie, .merkliste, .seerrTitel, .person, .gattung: false
        }
    }

    static func == (a: Seitenziel, b: Seitenziel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Welcher Bereich gerade sichtbar ist.
///
/// Über die Umgebung, weil jede Kachel tief im Baum wissen muss, auf welchen
/// Stapel sie legt — und ein durchgereichter Wert hätte durch jede Ansicht
/// dazwischen gemusst, die ihn selbst gar nicht braucht.
extension EnvironmentValues {
    @Entry var bereich: Bereich = .start
}

/// **Während eine Seite hereinfährt, wird nichts ausgetauscht.**
///
/// Die Fahrt ist ein `.offset`, und den rechnet SwiftUI in jedem Einzelbild
/// auf dem Hauptlauf. Kam in dieser Zeit eine Antwort vom Server — der volle
/// Titel, Staffeln und Folgen, Extras und Ähnliches, der Plan, der Bildton —,
/// baute SwiftUI im selben Lauf die halbe Seite neu aus, und die Fahrt verlor
/// Bilder: ein, zwei Zentimeter herein, kurz stehen, dann weiter. Genau das
/// Stocken in der ersten Sekunde nach dem Klick.
///
/// Also warten die Antworten, bis die Seite steht (Linux: `nachDemSchub`).
/// Abgerufen wird trotzdem sofort; nur das Einsetzen wartet, höchstens die
/// Dauer einer Fahrt. Wer auf eine stehende Seite zurückkehrt, wartet nicht.
@MainActor
enum Einfahrt {
    private static var ende = ContinuousClock.now

    /// Ruft `HauptView`, wenn eine neue Seite losfährt.
    static func beginnt() {
        // Ein Einzelbild Luft: das letzte Bild der Fahrt gehört noch ihr.
        ende = .now + .milliseconds(Int(Stil.dauerSeitenschub * 1000) + 30)
    }

    /// Kehrt zurück, sobald keine Seite mehr fährt.
    static func abwarten() async {
        guard ende > .now else { return }
        try? await Task.sleep(until: ende, clock: .continuous)
    }
}

/// **Wiedergabepläne, vorab geholt** — für den Beleg „Direct Play" im Kopf
/// der Detailseite. Beim Überfahren einer Kachel (nach der Frist der
/// `Kachelhuelle`) holt `vorholen` den Plan schon; liegt er beim Öffnen vor,
/// steht der Beleg sofort da, statt hinten nachzukommen. Der Kopf fragt
/// trotzdem frisch nach und zieht nach, falls sich etwas geändert hat.
///
/// Bei einer Serie ist es der Plan der Folge, die als Nächstes liefe — wie
/// im Kopf (`standInSerie`). Linux/Windows: `App.planAuftrag`.
@MainActor
enum Planvorrat {
    private static var gemerkt: [String: PlaybackPlan] = [:]
    private static var laufend: [String: Task<PlaybackPlan?, Never>] = [:]

    /// Wovon ein Plan abhängt: Direct-Play-Schalter, Bitratengrenze, Konto.
    /// Ändert sich eines, gelten die gemerkten Pläne nicht mehr — sonst zeigte
    /// der Kopf kurz „Direct Play", wo der neue Plan umwandelt.
    private static var schluessel = ""

    private static func abgleichen(_ model: AppModel) {
        let neu = "\(model.immerDirectPlay)|\(model.bitratenGrenze)|\(model.kontowechsel)"
        guard neu != schluessel else { return }
        schluessel = neu
        gemerkt.removeAll()
        laufend.values.forEach { $0.cancel() }
        laufend.removeAll()
    }

    static func plan(_ id: String, mit model: AppModel) -> PlaybackPlan? {
        abgleichen(model)
        return gemerkt[id]
    }

    static func merken(_ id: String, _ plan: PlaybackPlan?) {
        gemerkt[id] = plan
    }

    /// `PlaybackInfo` ist ein POST, bei dem der Server die Datei anfasst —
    /// je Titel einer, auch wenn Überfahren und Öffnen zusammenfallen.
    static func vorholen(_ item: Item, mit model: AppModel) {
        abgleichen(model)
        guard item.type == "Movie" || item.type == "Series",
              gemerkt[item.id] == nil, laufend[item.id] == nil else { return }
        let id = item.id
        let serie = item.type == "Series"
        laufend[id] = Task { @MainActor in
            let ziel: String?
            if serie { ziel = await model.standInSerie(item)?.id } else { ziel = id }
            guard let ziel else { laufend[id] = nil; return nil }
            let plan = await model.plan(for: ziel, still: true)
            // Abgebrochen (Einstellung oder Konto gewechselt): der Plan gilt nicht mehr.
            guard !Task.isCancelled else { return nil }
            if let plan { gemerkt[id] = plan }
            laufend[id] = nil
            return plan
        }
    }
}
