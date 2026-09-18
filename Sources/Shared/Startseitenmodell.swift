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
    /// Die gewählten Genres als eigene Reihen — nur, wenn keine Chips.
    private(set) var gattungsreihen: [Gattungsreihe] = []

    struct Gattungsreihe: Identifiable {
        let name: String
        let items: [Item]
        var id: String { name }
    }
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

    /// Zu welchem Kontostand der Inhalt gehört.
    private var fuerKonto = 0

    /// **Auch die Genrereihen zählen.** Wer alle festen Reihen ausblendet
    /// und nur Genres als Reihen zeigt, hat eine volle Startseite — ohne
    /// diese Zeile stünde der Leerzustand darüber.
    var alleLeer: Bool {
        weiterschauen.isEmpty && naechsteFolge.isEmpty
            && zuletzt.isEmpty && neueFilme.isEmpty && neueSerien.isEmpty
            && gattungsreihen.allSatisfy { $0.items.isEmpty }
    }

    func laden(_ model: AppModel) async {
        let diesesKonto = model.kontowechsel
        if model.views.isEmpty { await model.loadViews() }
        // Ohne Client kam nichts an — wie vorher, als die Hilfsfunktionen dann `nil` gaben.
        guard let client = model.client else {
            gestoert = !Task.isCancelled
            geladen = true
            return
        }
        let getrennt = model.neuzugangGetrennt
        // **Die Regel steht im Paket** (`Startseitenlader`), gemeinsam mit
        // Linux/Windows und Android. Hier wird nur noch in den Zustand
        // uebernommen — mit derselben Unterscheidung wie vorher: kam ein Abruf
        // nicht durch, bleibt der alte Stand, ausser nach einem Kontowechsel.
        let stand = await Startseitenlader.laden(von: client, .init(
            getrennt: getrennt,
            filmBibliothek: model.gewaehlteBibliothek(art: "movies")?.id,
            serienBibliothek: model.gewaehlteBibliothek(art: "tvshows")?.id,
            gattungen: nil,
            bisherWeiterschauen: weiterschauen))
        let wechsel = diesesKonto != fuerKonto
        fuerKonto = diesesKonto
        func uebernehmen(_ neu: [Item]?, _ alt: [Item]) -> [Item] {
            neu ?? (wechsel ? [] : alt)
        }
        weiterschauen = uebernehmen(stand.weiterschauen, weiterschauen)
        naechsteFolge = uebernehmen(stand.naechsteFolge, naechsteFolge)
        if getrennt {
            zuletzt = []
            neueFilme = uebernehmen(stand.neueFilme, neueFilme)
            neueSerien = uebernehmen(stand.neueSerien, neueSerien)
        } else {
            neueFilme = []
            neueSerien = []
            zuletzt = uebernehmen(stand.zuletzt, zuletzt)
        }
        gestoert = !Task.isCancelled && stand.gestoert
        if !gestoert { zuletztGeladen = Date() }
        geladen = true
        // Die Genre-Reihen danach — die festen Reihen stehen schon.
        gattungsreihen = model.genreChips ? [] :
            await Startseitenlader.gattungsreihen(von: client, namen: model.startGenres)
                .map { Gattungsreihe(name: $0.name, items: $0.items) }
        Serienspeicher.geteilt.vorholen(
            weiterschauen + naechsteFolge + zuletzt + neueSerien, mit: model)
    }

    /// Muss beim Zurückkommen in den Vordergrund neu geholt werden?
    var brauchtAuffrischung: Bool {
        Auffrischung.faelligBeiRueckkehr(zuletzt: zuletztGeladen)
    }
}
