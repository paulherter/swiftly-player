import Foundation
import JellyfinKit
import Observation

/// Was gemerkt ist, quer über alle Bibliotheken.
///
/// **Eine Bibliothek wie jede andere, nur ist ihre Grenze der Haken.** Nicht
/// ein Ordner auf der Platte, sondern was der Nutzer angetippt hat — und
/// deshalb sind Filme und Serien hier gemischt. Wer trennen will, nimmt die
/// Gattungspille; das ist dieselbe Frage wie in der Bibliothek, nur eine
/// Ebene höher gestellt.
///
/// Aufbau und Bausteine sind die der Bibliotheksseite: Kopf mit Titel,
/// Steuerzeile mit Werten und Zählmarke, darunter das Raster. Eine eigene
/// Seitenart wäre eine zweite Grammatik für dieselbe Sache.
@MainActor
@Observable
final class Merklistenmodell {
    private(set) var items: [Item] = []
    private(set) var gesamt = 0
    private(set) var laedt = true
    private var laedtNach = false

    /// `nil` heisst Filme **und** Serien.
    var gattung: String? { didSet { sichern() } }
    /// Zuletzt gemerkt zuerst — das ist die Reihenfolge, in der man eine
    /// Merkliste liest. A–Z wäre die Ordnung eines Regals, nicht die einer
    /// Absicht.
    ///
    /// **Und was man einmal waehlt, steht beim naechsten Mal wieder da.**
    /// Dieselbe Regel wie in `Bibliotheksmodell`, dieselbe Begruendung: eine
    /// Sortierung ist eine Einstellung, keine Handlung.
    var sortierung: Sortierung = .neueste { didSet { sichern() } }

    init() {
        let ablage = UserDefaults.standard
        if let roh = ablage.string(forKey: "sortierung.merkliste"),
           let wert = Sortierung(rawValue: roh) { sortierung = wert }
        gattung = ablage.string(forKey: "gattung.merkliste")
    }

    private func sichern() {
        let ablage = UserDefaults.standard
        ablage.set(sortierung.rawValue, forKey: "sortierung.merkliste")
        if let gattung { ablage.set(gattung, forKey: "gattung.merkliste") }
        else { ablage.removeObject(forKey: "gattung.merkliste") }
    }

    var kennung: String { "\(gattung ?? "-")|\(sortierung.rawValue)" }
    var nochMehrDa: Bool { items.count < gesamt }

    func nachladenAb(spalten: Int) -> String? {
        guard !items.isEmpty else { return nil }
        return items[max(0, items.count - 3 * spalten)].id
    }

    func laden(_ model: AppModel) async {
        laedt = items.isEmpty
        if let seite = await model.gemerkte(art: gattung, sortierung: sortierung, ab: 0) {
            // Dieselbe Regel wie auf der Startseite — siehe `Listenregeln`.
            items = Listenregeln.ohneDoppelte(seite.titel)
            gesamt = seite.gesamt
        }
        laedt = false
    }

    func nachladen(_ model: AppModel) async {
        guard nochMehrDa, !laedtNach, !laedt else { return }
        laedtNach = true
        defer { laedtNach = false }
        guard let seite = await model.gemerkte(art: gattung, sortierung: sortierung,
                                               ab: items.count) else { return }
        // Nur wirklich Neues anhängen: der Server kann eine Seite doppelt
        // liefern, und `ForEach` beschwert sich über die doppelte Kennung.
        let bekannt = Set(items.map(\.id))
        items += seite.titel.filter { !bekannt.contains($0.id) }
        gesamt = seite.gesamt
    }
}

/// Die Gattungen, zwischen denen die Merkliste unterscheidet.
enum Merkgattung: String, CaseIterable, Identifiable {
    case alle, filme, serien
    var id: String { rawValue }

    /// **Nicht „Alle".** Auf der Bibliotheksseite steht an derselben Stelle
    /// eine Pille mit demselben Wort — die meint dort aber den *Zustand*
    /// (alle, angefangen, gemerkt, ungesehen), hier die *Gattung*. Gleiches
    /// Wort, gleiches Zeichen, gleicher Platz, zwei Bedeutungen: das ist
    /// keine Kürze, sondern eine Falle.
    var beschriftung: String {
        switch self {
        case .alle:   String(localized: "Filme & Serien")
        case .filme:  String(localized: "Filme")
        case .serien: String(localized: "Serien")
        }
    }

    /// Jellyfins `CollectionType`, wie ihn `AppModel.gemerkte` erwartet.
    var art: String? {
        switch self {
        case .alle:   nil
        case .filme:  "movies"
        case .serien: "tvshows"
        }
    }

    /// Aus der gemerkten Gattung wieder eine Pille machen — die Ansicht
    /// haelt ihren Chip getrennt vom Modell, und beim Start muessen beide
    /// dasselbe sagen.
    static func zu(art: String?) -> Merkgattung {
        allCases.first { $0.art == art } ?? .alle
    }
}
