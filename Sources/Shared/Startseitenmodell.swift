import Foundation
import JellyfinKit
import Observation

/// Was die Startseite anzeigt und wie sie es lädt — für beide Plattformen.
///
/// Lag vorher zweimal fast gleich in `HomeView`: einmal iPhone, einmal
/// Fernseher. „Fast gleich" ist dabei die Gefahr — ändert jemand auf einer
/// Seite die Reihenfolge oder das Ausfallverhalten, merkt es die andere
/// Seite nicht. Das Laden gehört deshalb hierher, und die Ansichten zeigen
/// nur noch an.
@MainActor
@Observable
final class Startseitenmodell {
    private(set) var weiterschauen: [Item] = []
    private(set) var naechsteFolge: [Item] = []
    private(set) var zuletzt: [Item] = []
    private(set) var geladen = false
    /// Kein einziger der drei Aufrufe kam durch — dann liegt es am Server,
    /// nicht am leeren Bestand.
    private(set) var gestoert = false

    /// Wann zuletzt geholt wurde. Grundlage für `Auffrischung`.
    ///
    /// **Nur bei Erfolg gesetzt.** Ein Ladeversuch, bei dem nichts ankam,
    /// macht die Reihen nicht frisch — sonst gilt der Bestand nach einem
    /// Serveraussetzer eine halbe Minute lang als aktuell, obwohl er
    /// unverändert alt ist.
    private(set) var zuletztGeladen: Date?

    var alleLeer: Bool {
        weiterschauen.isEmpty && naechsteFolge.isEmpty && zuletzt.isEmpty
    }

    func laden(_ model: AppModel) async {
        async let angefangen = model.weiterschauen()
        async let neues = model.zuletztHinzugefuegt()
        if model.views.isEmpty { await model.loadViews() }

        let a = await angefangen
        // Erst danach, weil die Reihe wissen muss, was oben schon steht.
        let b = await model.naechsteFolge(ohne: a ?? weiterschauen)
        let c = await neues

        // Nur übernehmen, was auch wirklich geantwortet hat. Sonst räumt ein
        // einzelner Aussetzer die ganze Seite leer — genau das ist passiert.
        if let a { weiterschauen = a }
        if let b { naechsteFolge = b }
        if let c { zuletzt = c }

        gestoert = (a == nil && b == nil && c == nil)
        if !gestoert { zuletztGeladen = Date() }
        geladen = true
    }

    /// Muss beim Zurückkommen in den Vordergrund neu geholt werden?
    var brauchtAuffrischung: Bool {
        Auffrischung.faelligBeiRueckkehr(zuletzt: zuletztGeladen)
    }
}
