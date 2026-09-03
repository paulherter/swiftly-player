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
    /// Nur gefüllt, wenn `AppModel.neuzugangGetrennt` an ist.
    ///
    /// **Getrennt statt zusätzlich.** Ist die Einstellung an, ersetzt dieses
    /// Paar die Reihe `zuletzt`; ist sie aus, bleibt es leer und es wird auch
    /// nichts dafür geholt. So kostet die Einstellung nichts, solange sie
    /// niemand benutzt — und tvOS und macOS, die dieses Modell mitbenutzen,
    /// merken nichts davon.
    private(set) var neueFilme: [Item] = []
    private(set) var neueSerien: [Item] = []
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
        weiterschauen.isEmpty && naechsteFolge.isEmpty
            && zuletzt.isEmpty && neueFilme.isEmpty && neueSerien.isEmpty
    }

    func laden(_ model: AppModel) async {
        async let angefangen = model.weiterschauen()
        // **Die Bibliotheken müssen vorher bekannt sein.** Getrennt geholt
        // wird je Bibliothek, und deren Kennung steht erst nach `loadViews`.
        if model.views.isEmpty { await model.loadViews() }

        let getrennt = model.neuzugangGetrennt
        async let neues = getrennt ? nil : model.zuletztHinzugefuegt()
        async let filme = getrennt
            ? model.zuletztHinzugefuegt(in: model.gewaehlteBibliothek(art: "movies")?.id)
            : nil
        async let serien = getrennt
            ? model.zuletztHinzugefuegt(in: model.gewaehlteBibliothek(art: "tvshows")?.id)
            : nil

        let a = await angefangen
        // Erst danach, weil die Reihe wissen muss, was oben schon steht.
        let b = await model.naechsteFolge(ohne: a ?? weiterschauen)
        let c = await neues
        let d = await filme
        let e = await serien

        // Nur übernehmen, was auch wirklich geantwortet hat. Sonst räumt ein
        // einzelner Aussetzer die ganze Seite leer — genau das ist passiert.
        if let a { weiterschauen = a }
        if let b { naechsteFolge = b }
        // **Die nicht gewaehlte Form wird geleert, nicht bloss nicht
        // geholt.** Sonst bliebe die Reihe von vorhin stehen: wer umschaltet,
        // saehe „Zuletzt hinzugefuegt" **und** die beiden neuen. Genau das
        // ist beim ersten Versuch passiert.
        if getrennt {
            zuletzt = []
            if let d { neueFilme = d }
            if let e { neueSerien = e }
        } else {
            neueFilme = []
            neueSerien = []
            if let c { zuletzt = c }
        }

        // Ein Abbruch ist kein Ausfall — dieselbe Unterscheidung wie in
        // `Bibliotheksmodell`.
        // Bei getrennten Reihen zählen die beiden statt der einen.
        let neuesDa = getrennt ? (d != nil || e != nil) : c != nil
        gestoert = !Task.isCancelled && a == nil && b == nil && !neuesDa
        if !gestoert { zuletztGeladen = Date() }
        geladen = true
    }

    /// Muss beim Zurückkommen in den Vordergrund neu geholt werden?
    var brauchtAuffrischung: Bool {
        Auffrischung.faelligBeiRueckkehr(zuletzt: zuletztGeladen)
    }
}
