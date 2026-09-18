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
    /// Fuer die Sammlungen neben Filme und Serien. Sie schalten den
    /// Filme-Bereich ausdruecklich **nicht** um Vorher taten sie genau das,
    /// und dann stand ueber "Filmabend" die Ueberschrift "Filme".
    case bibliothek(Item)
    /// **Nicht mehr in Gebrauch.** Die Merkliste ist seit dem 06.09.2026 ein
    /// eigener Bereich in der Leiste; der Fall bleibt nur stehen, damit ein
    /// alter, wiederhergestellter Stapel nicht bricht.
    ///
    /// Vorher: eine Seite aus der
    /// Leiste. Auf dem iPhone haengt sie am Zeichen oben rechts.
    case merkliste
    /// Seerr anbinden — eine Zugabe, deshalb hinter den Einstellungen.
    case seerr
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
        case .merkliste:        "merkliste"
        case .seerr:            "seerr"
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
        case .profil, .einstellungen, .wiedergabe, .seerr, .darstellung,
             .genrewahl, .quickConnect, .kontoHinzufuegen, .serverHinzufuegen: true
        // **Die Personenseite gehoert zum Bereich, nicht zum Konto.** Man
        // kommt aus einem Titel dorthin und will von dort weiter in den
        // naechsten — sie liegt im selben Zweig wie die Seite, die sie
        // geoeffnet hat. Dasselbe gilt fuer ein Genre.
        case .titel, .bibliothek, .merkliste, .seerrTitel, .person, .gattung: false
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
