import Foundation

// MARK: - Was im Titelmenü eines Bereichs steht

/// Eine Wahl im Menü am Titel von „Filme" bzw. „Serien".
///
/// **Sammlungen sind keine Bibliothek.** Deshalb stehen sie nicht am Ende
/// der Bibliotheksliste, sondern direkt unter „Alle": sie sind eine andere
/// Sicht auf denselben Bestand, kein weiterer Ordner auf der Platte. So wurde
/// es am Entwurf vom 22.09.2026 korrigiert.
public enum Bereichswahl: Hashable, Sendable, Identifiable {
    /// Jeder Titel dieser Gattung aus jeder Bibliothek. Voreingestellt.
    case alle
    /// Die Sammlungen (Jellyfin: `BoxSet`) mit Titeln dieser Gattung.
    case sammlungen
    /// Eine einzelne Bibliothek, über ihre Kennung.
    case bibliothek(String)

    public var id: String { merkwert }

    /// Wie die Wahl liegen bleibt.
    ///
    /// **Unter demselben Namen wie bisher die Bibliothek** — wer vor dem
    /// Umbau eine von zwei Filmbibliotheken gewählt hatte, landet danach
    /// weiter dort, denn deren Kennung ist genau dieser Wert.
    public var merkwert: String {
        switch self {
        case .alle:               "alle"
        case .sammlungen:         "sammlungen"
        case .bibliothek(let id): id
        }
    }

    public init(merkwert: String?) {
        switch merkwert {
        case nil, "", "alle": self = .alle
        case "sammlungen":    self = .sammlungen
        case let id?:         self = .bibliothek(id)
        }
    }
}

/// Wie viele Filme und Serien in einer Bibliothek liegen, die beides
/// enthalten kann.
public struct Bibliotheksanteil: Sendable, Equatable {
    public var filme: Int
    public var serien: Int

    public init(filme: Int, serien: Int) {
        self.filme = filme
        self.serien = serien
    }

    /// - Parameter art: `movies` oder `tvshows`.
    public func anzahl(art: String) -> Int {
        switch art.lowercased() {
        case "movies":  filme
        case "tvshows": serien
        default:        0
        }
    }
}

/// **Was der Titel eines Bereichs zur Wahl anbietet** — und ob er überhaupt
/// ein Menü ist.
///
/// Die Regel: *Der Titel wird zum Menü, sobald es darin mehr als eine Sache
/// zu wählen gibt.* Wer eine Filmbibliothek, eine Serienbibliothek und keine
/// Sammlungen hat, sieht deshalb genau das, was er vorher sah — kein Winkel,
/// kein Tippziel.
///
/// Reihenfolge im Menü: „Alle", dann „Sammlungen", dann unter der Rubrik
/// „Bibliotheken" die einzelnen Bibliotheken in der Reihenfolge des Servers
/// (die kommt aus `OrderedViews` des Kontos, `UserViews` liefert sie so).
public struct Bereichsangebot: Sendable, Equatable {
    /// `movies` oder `tvshows`.
    public let art: String
    /// Jede Bibliothek mit Titeln dieser Gattung — auch eine einzige.
    public let bibliotheken: [Item]
    /// Wie viele Sammlungen ab der Schwelle in diesem Bereich stehen.
    public let sammlungen: Int

    public init(art: String, bibliotheken: [Item], sammlungen: Int) {
        self.art = art
        self.bibliotheken = bibliotheken
        self.sammlungen = sammlungen
    }

    /// **Eine Bibliothek allein ist keine Wahl.** Sie zeigte dasselbe wie
    /// „Alle" — zwei Einträge, ein Inhalt.
    public var zeigtBibliotheken: Bool { bibliotheken.count > 1 }
    public var zeigtSammlungen: Bool { sammlungen > 0 }
    public var istMenue: Bool { zeigtBibliotheken || zeigtSammlungen }

    public var eintraege: [Bereichswahl] {
        var liste: [Bereichswahl] = [.alle]
        if zeigtSammlungen { liste.append(.sammlungen) }
        if zeigtBibliotheken { liste += bibliotheken.map { .bibliothek($0.id) } }
        return liste
    }

    /// Vor welchem Eintrag der Trennstrich und die Rubrik „Bibliotheken"
    /// stehen — vor der ersten Bibliothek, wenn es sie im Menü gibt.
    public var ersteBibliothek: Bereichswahl? {
        zeigtBibliotheken ? bibliotheken.first.map { .bibliothek($0.id) } : nil
    }

    public func bibliothek(_ id: String) -> Item? {
        bibliotheken.first { $0.id == id }
    }

    /// Die gemerkte Wahl, sofern es sie noch gibt — sonst „Alle".
    ///
    /// Verschwindet eine Bibliothek oder blendet jemand die Sammlungen in
    /// Jellyfin aus, fällt die Seite still auf „Alle" zurück, statt leer
    /// dazustehen.
    public func wahl(gemerkt: String?) -> Bereichswahl {
        let wunsch = Bereichswahl(merkwert: gemerkt)
        return eintraege.contains(wunsch) ? wunsch : .alle
    }

    /// **Woraus „Alle" liest: die Bibliotheken dieser Gattung — nicht die
    /// gemischten.**
    ///
    /// Rückmeldung vom 22.09.2026 am iPhone: „Alle Filme" zeigte Folgen von Game of
    /// Thrones. Gemessen: Jellyfin führt lose Videodateien in einer
    /// gemischten Bibliothek als `Movie` — 13 „Filme" der Testbibliothek
    /// waren Folgen mit `S01E01` im Namen. Eine Gattung, die der Server so
    /// vergibt, lässt sich nicht nachträglich sortieren. Also zählt eine
    /// gemischte Bibliothek zu „Alle" nur, wenn es in diesem Bereich keine
    /// eigene gibt; wählbar bleibt sie im Menü mit ihrem Anteil.
    public var alleQuellen: [String] {
        let eigene = bibliotheken.filter { $0.collectionType?.lowercased() == art.lowercased() }
        return (eigene.isEmpty ? bibliotheken : eigene).map(\.id)
    }

    /// Die eine Bibliothek, wenn „Alle" nur aus einer liest — dann ist die
    /// Abfrage dieselbe wie vor dem Umbau. Sonst `nil`: aus mehreren, über
    /// ``Titelsieb``.
    public var alleAus: String? {
        alleQuellen.count == 1 ? alleQuellen[0] : nil
    }

    /// Ob es in diesem Bereich überhaupt etwas zu zeigen gibt.
    public var hatBestand: Bool { !bibliotheken.isEmpty }

    /// - Parameters:
    ///   - views: Die Bibliotheken des Kontos (`UserViews`). Was der Nutzer in
    ///     Jellyfin unter „Meine Medien" ausgeblendet hat, fehlt hier schon.
    ///   - anteile: Filme und Serien je gemischter Bibliothek. Fehlt eine,
    ///     steht sie (noch) nirgends.
    ///   - verzeichnis: Die Sammlungen, `nil` solange unbekannt.
    public static func bilden(art: String, views: [Item],
                              anteile: [String: Bibliotheksanteil],
                              verzeichnis: Sammlungsverzeichnis?) -> Bereichsangebot {
        let passend = views.filter { gehoert($0, zu: art, anteile: anteile) }
        return Bereichsangebot(art: art, bibliotheken: passend,
                               sammlungen: verzeichnis?.sammlungen(art: art).count ?? 0)
    }

    /// **Eine gemischte Bibliothek steht in beiden Bereichen** — unter Filme
    /// mit ihren Filmen, unter Serien mit ihren Serien. Aber nur dort, wo sie
    /// etwas hat: leere Einträge gibt es nicht.
    static func gehoert(_ view: Item, zu art: String,
                        anteile: [String: Bibliotheksanteil]) -> Bool {
        let typ = view.collectionType?.lowercased()
        if typ == art.lowercased() { return true }
        guard Bibliotheksgattung.kannGemischtSein(typ) else { return false }
        return (anteile[view.id]?.anzahl(art: art) ?? 0) > 0
    }
}

extension Bibliotheksgattung {

    /// Ob in einer Bibliothek dieser Art Filme **und** Serien liegen können.
    ///
    /// **Keine Sonderfälle.** Die Bibliotheken kommen so, wie der Server sie
    /// hat: bei allem, was nicht eindeutig nur eine Sorte trägt, wird
    /// gezählt, und die Zahl entscheidet. Eine Heimvideo-Bibliothek hat für
    /// Jellyfin keine Filme, sondern Videos — sie fällt dabei von selbst
    /// heraus, ohne dass hier jemand „Heimvideos" buchstabiert.
    public static func kannGemischtSein(_ art: String?) -> Bool {
        let eindeutig: Set<String> = ["movies", "tvshows", "music", "musicvideos",
                                      "books", "photos", "livetv", "playlists",
                                      "boxsets", "trailers"]
        guard let art = art?.lowercased() else { return true }
        return !eindeutig.contains(art)
    }

    /// Welcher Bereich zu einer Titelgattung gehört: `Movie` → `movies`.
    public static func art(zuTyp typ: String?) -> String? {
        switch typ {
        case "Movie":  "movies"
        case "Series": "tvshows"
        default:       nil
        }
    }
}

// MARK: - Woraus eine Rasterseite liest

/// **Woraus eine Bibliotheks- oder Sammlungsseite ihre Titel holt.**
///
/// Drei Quellen, eine Seite: eine Bibliothek, „Alle" (ohne `ParentId`, quer
/// über alle Bibliotheken) und eine Sammlung. Die Unterschiede stehen hier
/// und nicht in der Ansicht, damit Mac, Fernseher und Android dieselben
/// Abfragen stellen.
public struct Regalquelle: Equatable, Sendable {
    /// Bibliothek oder Sammlung. `nil` heißt: aus mehreren Bibliotheken.
    public let eltern: String?
    /// Ohne `eltern`: aus genau diesen Bibliotheken. Jellyfin fragt ohne
    /// `ParentId` über **alle** Bibliotheken des Kontos, auch die in „Meine
    /// Medien" ausgeblendeten und die gemischten; was nicht von hier kommt,
    /// siebt ``Titelsieb`` heraus.
    public let nurAus: [String]
    /// Der Bereich, `movies` oder `tvshows`. Bestimmt die Gattung.
    public let art: String?
    public let sammlung: Bool

    public init(eltern: String?, art: String?, sammlung: Bool = false, nurAus: [String] = []) {
        self.eltern = eltern
        self.art = art
        self.sammlung = sammlung
        self.nurAus = nurAus
    }

    /// Aus mehreren Bibliotheken — dann gesiebt: je Titel einmal, und nur,
    /// was aus `nurAus` stammt.
    public var siebt: Bool { eltern == nil && !nurAus.isEmpty }

    public var typen: [String] { Bibliotheksgattung.typen(zu: art) }

    /// **Eine Sammlung wird nicht rekursiv gefragt.** Ihre Titel sind
    /// verknüpft, nicht einsortiert; die erste Ebene ist genau der Inhalt.
    /// Rekursiv käme bei einer Sammlung mit Serien jede Staffel und jede
    /// Folge mit, die erst die Gattung wieder aussortieren müsste.
    ///
    /// „Alle" dagegen muss rekursiv fragen, sonst liefert Jellyfin ohne
    /// `ParentId` nur die obersten Ordner.
    public var rekursiv: Bool {
        if sammlung { return false }
        if eltern == nil { return true }
        return Bibliotheksgattung.rekursiv(zu: art)
    }

    /// **In einer Sammlung läuft das Jahr aufsteigend** — damit eine Reihe
    /// in ihrer Folge steht, Teil 1 vor Teil 2. Überall sonst gilt die
    /// Richtung der Sortierung.
    public func richtung(_ sortierung: Sortierung) -> String {
        sammlung && sortierung == .erscheinung ? "Ascending" : sortierung.richtung
    }

    /// Wofür geladen wurde — wechselt es, wird ersetzt statt aufgefrischt.
    public var schluessel: String {
        "\(eltern ?? nurAus.joined(separator: "+"))|\(art ?? "")|\(sammlung ? "s" : "b")"
    }
}

// MARK: - Aus mehreren Bibliotheken, je Titel einmal

/// **„Alle Filme" sieht aus wie eine Bibliothek, nicht wie ihre Summe.**
///
/// Gemessen am 22.09.2026 am Testserver: „Filme", „Kinoabend" und
/// „Videothek" sind Hardlinks auf dieselben Dateien, Jellyfin führt jeden
/// Film dort mit eigener Kennung — ohne `ParentId` kamen 20 Filme zurück,
/// davon 16 verschiedene, und 13 davon aus der gemischten Bibliothek.
///
/// Der Server sortiert und blättert (eine Abfrage ohne `ParentId`), das Sieb
/// lässt nur durch, was aus den gewählten Bibliotheken stammt und als Titel
/// noch nicht dastand (``Listenregeln/jeTitelEinmal(_:zeigen:)``, dieselbe
/// Regel wie bei „Zuletzt hinzugefügt"). Es merkt sich das über Seiten
/// hinweg — sonst stünde ein Film, dessen zweite Kopie erst auf Seite drei
/// kommt, eben doch zweimal da.
///
/// Wer aus welcher Bibliothek stammt, sagt die Antwort nicht; deshalb holt
/// die Seite vorher die Kennungen der gewählten Bibliotheken (``erlaubt``),
/// schlank und mit denselben Filtern. Daraus steht auch die Anzahl fest.
public struct Titelsieb: Sendable {
    private let erlaubt: Set<String>
    /// Wie viele verschiedene Titel es gibt.
    public let gesamt: Int
    private var gesehen = Set<String>()

    /// - Parameter kennungen: Alles aus den gewählten Bibliotheken, mit
    ///   Gattung, Namen, Jahr und Anbieternummern.
    public init(kennungen: [Item]) {
        erlaubt = Set(kennungen.map(\.id))
        gesamt = Set(kennungen.map(Listenregeln.titelschluessel)).count
    }

    /// Was von einer Seite stehen bleibt, in ihrer Reihenfolge.
    public mutating func sieben(_ seite: [Item]) -> [Item] {
        seite.filter { erlaubt.contains($0.id) && gesehen.insert(Listenregeln.titelschluessel($0)).inserted }
    }

    /// Von vorn — beim Neuladen der ersten Seite.
    public mutating func vonVorn() { gesehen = [] }
}
