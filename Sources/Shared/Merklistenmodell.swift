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
    var nochMehrDa: Bool { Listenregeln.nochMehrDa(geladen: items.count, gesamt: gesamt) }

    func loestNachladenAus(_ id: String, spalten: Int) -> Bool {
        Listenregeln.imNachladebereich(id, in: items, spalten: spalten)
    }

    /// Dieselbe Unterscheidung wie in `Bibliotheksmodell`: gleiche Liste
    /// wird aufgefrischt, nicht auf die erste Seite gekürzt.
    private var geladenFuer: String?

    func laden(_ model: AppModel) async {
        laedt = items.isEmpty
        if let seite = await model.gemerkte(art: gattung, sortierung: sortierung, ab: 0) {
            // Dieselbe Regel wie auf der Startseite — siehe `Listenregeln`.
            let fuer = "\(kennung)|\(model.kontowechsel)"
            items = geladenFuer == fuer
                ? Listenregeln.auffrischen(seite.titel, in: items,
                                           gesamtVorher: gesamt, gesamtJetzt: seite.gesamt)
                : Listenregeln.ohneDoppelte(seite.titel)
            geladenFuer = fuer
            gesamt = seite.gesamt
        }
        laedt = false
    }

    func nachladen(_ model: AppModel) async {
        guard nochMehrDa, !laedtNach, !laedt else { return }
        laedtNach = true
        defer { laedtNach = false }
        let vorher = geladenFuer
        guard let seite = await model.gemerkte(art: gattung, sortierung: sortierung,
                                               ab: items.count),
              geladenFuer == vorher else { return }
        // Nur wirklich Neues anhängen: der Server kann eine Seite doppelt
        // liefern, und `ForEach` beschwert sich über die doppelte Kennung.
        items = Listenregeln.anhaengen(seite.titel, an: items)
        gesamt = seite.gesamt
    }
}

// `Merkgattung` liegt seit dem 13.09.2026 im Paket (`Bibliothek.swift`) —
// sie stand hier und erreichte Linux und Windows deshalb nicht.
