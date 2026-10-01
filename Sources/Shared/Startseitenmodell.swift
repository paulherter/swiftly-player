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

    /// Die gewählten Bibliotheken und Sammlungen als eigene Reihen. Gezeigt
    /// wird in der Folge der Wahl (`bibliotheksreihen(fuer:)`), nicht in der
    /// des Abrufs.
    private(set) var bibliotheksreihen: [Startseite.Bibliotheksreihe] = []

    /// Die Reihen zur **jetzigen** Wahl: was nicht mehr gewählt ist, fällt
    /// sofort weg, auch wenn der nächste Abruf noch läuft.
    func bibliotheksreihen(fuer wahl: [Startbibliothek]) -> [Startseite.Bibliotheksreihe] {
        let je = Dictionary(bibliotheksreihen.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return wahl.compactMap { je[$0.id] }
    }

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

    /// **Wie viele Läufe gerade unterwegs sind.** Nur für
    /// ``brauchtAuffrischung``: solange einer läuft, ist nichts fällig.
    private var laufendeLaeufe = 0

    /// Zu welchem Kontostand der Inhalt gehört.
    private var fuerKonto = 0
    /// Zählt jeden Ladelauf. **Nur der jüngste schreibt.** Angestossen wird
    /// von mehreren Stellen — Kontowechsel, Einstellung, Rückkehr aus dem
    /// Player, Ziehen zum Aktualisieren —, und die Läufe überholen sich: ein
    /// älterer, der später ankommt, schrieb sonst seinen Stand über den
    /// neueren, nach einem Kontowechsel sogar den des vorigen Kontos.
    private var lauf = 0

    /// **Auch die Genrereihen zählen.** Wer alle festen Reihen ausblendet
    /// und nur Genres als Reihen zeigt, hat eine volle Startseite — ohne
    /// diese Zeile stünde der Leerzustand darüber.
    var alleLeer: Bool {
        weiterschauen.isEmpty && naechsteFolge.isEmpty
            && zuletzt.isEmpty && neueFilme.isEmpty && neueSerien.isEmpty
            && gattungsreihen.allSatisfy { $0.items.isEmpty }
            && bibliotheksreihen.isEmpty
    }

    /// Der Stand gehört zu einem früheren Konto — die Startseite war beim
    /// Wechsel nicht im Baum und hat ihn nicht mitbekommen.
    func veraltet(_ model: AppModel) -> Bool { fuerKonto != model.kontowechsel }

    func laden(_ model: AppModel) async {
        let diesesKonto = model.kontowechsel
        laufendeLaeufe += 1
        defer { laufendeLaeufe -= 1 }
        lauf += 1
        let meiner = lauf
        /// Nach jedem `await`: gilt dieser Lauf noch?
        func gilt() -> Bool { meiner == lauf && diesesKonto == model.kontowechsel }
        // **Nach einem Kontowechsel sofort leer**, nicht erst, wenn die
        // Antwort da ist. Bis dahin stand die Startseite des vorigen Kontos
        // unter dem neuen Profilbild, und dann wechselte Reihe um Reihe.
        // Jetzt stehen die Platzhalter, und das neue Konto blendet in einem
        // Zug ein (siehe unten).
        if diesesKonto != fuerKonto, geladen || !alleLeer { leeren() }
        // **Erst der Stand vom letzten Mal, dann der Server** — siehe
        // `Startseitenablage`. Nur, solange noch nichts dasteht: beim
        // Auffrischen bleibt ohnehin der alte Stand stehen, bis der neue da ist.
        if !geladen, alleLeer, let konto = model.session?.kontoschluessel,
           let ablage = await Self.ablageLesen(konto) {
            guard gilt() else { return }
            if alleLeer { vorschauZeigen(ablage, model: model) }
            fuerKonto = diesesKonto
        }
        if model.views.isEmpty {
            await model.loadViews()
        } else if !geladenVomServer {
            // Die Bibliotheken kamen aus der Ablage: frisch holen, aber nicht
            // darauf warten — die Reihen brauchen nur ihre Kennungen.
            Task { await model.loadViews() }
        }
        guard gilt() else { return }
        // Ohne Client kam nichts an — wie vorher, als die Hilfsfunktionen dann `nil` gaben.
        guard let client = model.client else {
            gestoert = !Task.isCancelled
            geladen = true
            return
        }
        let getrennt = model.neuzugangGetrennt

        // **Die Genre-Reihen laufen nebenher, nicht hinterher.**
        //
        // Ihr Abruf stand am Ende dieser Funktion und wurde erst gestartet,
        // wenn die festen Reihen schon da waren — also **nach** einem
        // vollstaendigen Netzweg. Am Geraet hiess das: man scrollt nach unten,
        // dort ist nichts, und irgendwann erscheint die letzte Kategorie auf
        // einen Schlag. Rückmeldung vom 22.09.: „beim Runterscrollen erscheint die
        // letzte Kategorie random einfach zack da, auch viel zu spaet."
        //
        // Der Gedanke dahinter war richtig — die festen Reihen sollen zuerst
        // stehen —, nur ist „zuerst **anzeigen**" nicht dasselbe wie „zuerst
        // **abrufen**". `async let` startet den Abruf sofort und wird erst
        // unten eingesammelt: die festen Reihen erscheinen wie bisher als
        // erste, die Genres kommen aber um einen Netzweg frueher.
        async let gattungen = model.genreChips ? [] :
            Startseitenlader.gattungsreihen(von: client, namen: model.startGenres)
                .map { Gattungsreihe(name: $0.name, items: $0.items) }

        // **Die Bibliotheksreihen laufen ebenso nebenher**, alle zugleich und
        // höchstens einmal je Lauf. Eine Bibliothek, die es nicht mehr gibt
        // oder die dem Profil nicht gehört, liefert nichts und fällt still weg.
        let wahl = model.startBibliotheken
        async let bibliotheksstand: [Startseite.Bibliotheksreihe] = wahl.isEmpty ? [] :
            Startseitenlader.bibliotheksreihen(von: client, wahl: wahl)

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
        guard gilt() else { return }
        // **Abgebrochen heißt nicht „Server stumm".** Sonst gälten alle
        // Abrufe als `nil`: `geladen = true`, leere Reihen und „Hier ist noch
        // nichts", bis der Neustart des `task` durch ist.
        guard !Task.isCancelled else { return }
        // **Beim ersten Einblenden alles in einem Zug.** Steht noch nichts
        // da — erster Start oder frisch nach einem Kontowechsel —, wartet die
        // Seite auch auf die Genres, statt sie einen Moment spaeter unter die
        // festen Reihen zu schieben. Sie laufen ohnehin nebenher (oben);
        // beim Auffrischen einer stehenden Seite bleibt es beim Nachreichen.
        let ersteMal = !geladen
        let vorab: [Gattungsreihe]? = ersteMal ? await gattungen : nil
        let vorabBibliotheken: [Startseite.Bibliotheksreihe]? = ersteMal ? await bibliotheksstand : nil
        guard gilt() else { return }
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
        // Kam nur einer der festen Abrufe nicht durch, bleibt der alte Stand
        // stehen — und gilt nicht als frisch: die nächste Rückkehr holt neu,
        // statt die veraltete Reihe über die Frist hinaus zu halten.
        let teilausfall = stand.weiterschauen == nil || stand.naechsteFolge == nil
        if !gestoert, !teilausfall { zuletztGeladen = Date() }
        geladen = true
        // **Und der alte Stand bleibt stehen, bis der neue da ist.**
        //
        // Hier wurde die Liste beim Auffrischen erst geleert und dann neu
        // gefuellt — die Reihen verschwanden also und kamen wieder, jedes Mal,
        // wenn man hoch und wieder runter ging. Genau die Unterscheidung, die
        // `uebernehmen` fuer alle anderen Reihen seit jeher trifft: ein leeres
        // Ergebnis nach einem Kontowechsel heisst leer, sonst heisst es „der
        // Abruf kam nicht durch".
        if let vorab {
            gattungsreihen = vorab
        } else {
            let frische = await gattungen
            guard gilt() else { return }
            if !frische.isEmpty || wechsel || model.genreChips { gattungsreihen = frische }
        }
        if let vorabBibliotheken {
            bibliotheksreihen = vorabBibliotheken
        } else {
            let frische = await bibliotheksstand
            guard gilt() else { return }
            if !frische.isEmpty || wechsel || wahl.isEmpty { bibliotheksreihen = frische }
        }
        // **Nicht auf dem Fernseher.** Das Vorholen fuellt den Vorrat, den
        // `Serienspeicher.serie(fuer:mit:)` liest — und das tun nur iPhone,
        // iPad und Mac auf dem Weg von einer Folge zu ihrer Serie. tvOS geht
        // ueber `Serienspeicher.stand` und `Item.vorlaeufigeSerie`. Gemessen
        // am 25.09.2026 im tvOS-Simulator: 18 Einzelabrufe `Items/<id>`
        // gleichzeitig mit den ersten Plakaten, deren Ergebnis niemand las.
        if !gestoert {
            geladenVomServer = true
            if let konto = model.session?.kontoschluessel { ablageSchreiben(konto, model: model) }
            // Sammlungen und Anteile gemischter Bibliotheken vorab — die
            // Detailseite zeigt ihre Sammlungsreihe sonst erst nach zwei
            // weiteren Abrufen.
            Task { await model.angebotLaden() }
        }
        #if !os(tvOS)
        Serienspeicher.geteilt.vorholen(
            weiterschauen + naechsteFolge + zuletzt + neueSerien, mit: model)
        #else
        // **Wo es weitergeht, steht in diesen Reihen schon da** — die Folge
        // in „Naechste Folge" und „Weiterschauen" ist die vom Server. Der
        // Hauptknopf der Serienseite nennt sie damit sofort. Weiterschauen
        // zuletzt: eine angefangene Folge geht vor.
        Serienspeicher.geteilt.naechsteMerken(aus: naechsteFolge)
        Serienspeicher.geteilt.naechsteMerken(aus: weiterschauen)
        // **Auf dem Fernseher gebuendelt, je Reihe eine Anfrage** — fuer die
        // Angabenzeile im Kopf. Niedrige Prioritaet und erst jetzt, nach dem
        // Laden der Reihen: die Plakate gehen vor. Siehe
        // `Serienspeicher.vorholenGebuendelt`.
        for reihe in [weiterschauen, naechsteFolge, zuletzt] where !reihe.isEmpty {
            Task(priority: .utility) {
                await Serienspeicher.geteilt.vorholenGebuendelt(reihe, mit: model)
            }
        }
        #endif
    }

    // MARK: - Ablage

    /// Ob dieser Stand schon einmal vom Server kam — bis dahin stammen die
    /// Bibliotheken womöglich aus der Ablage und werden nebenher aufgefrischt.
    private var geladenVomServer = false

    private func vorschauZeigen(_ ablage: Startseitenablage, model: AppModel) {
        model.bibliothekenVorab(ablage.bibliotheken)
        let getrennt = model.neuzugangGetrennt
        weiterschauen = ablage.weiterschauen
        naechsteFolge = ablage.naechsteFolge
        zuletzt = getrennt ? [] : ablage.zuletzt
        neueFilme = getrennt ? ablage.neueFilme : []
        neueSerien = getrennt ? ablage.neueSerien : []
        // Nur Genres, die noch gewählt sind, in der gewählten Reihenfolge.
        let je = Dictionary(ablage.gattungsreihen.map { ($0.name, $0.items) },
                            uniquingKeysWith: { a, _ in a })
        gattungsreihen = model.genreChips ? [] : model.startGenres.compactMap { name in
            je[name].map { Gattungsreihe(name: name, items: $0) }
        }
        geladen = true
    }

    private static var ablageOrdner: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Startseite", isDirectory: true)
    }

    private static func ablageLesen(_ konto: String) async -> Startseitenablage? {
        guard let ordner = ablageOrdner else { return nil }
        let datei = ordner.appendingPathComponent(Startseitenablage.dateiname(konto: konto))
        return await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: datei)).flatMap(Startseitenablage.lesen)
        }.value
    }

    private func ablageSchreiben(_ konto: String, model: AppModel) {
        guard let ordner = Self.ablageOrdner else { return }
        let ablage = Startseitenablage(
            bibliotheken: model.views, weiterschauen: weiterschauen,
            naechsteFolge: naechsteFolge, zuletzt: zuletzt, neueFilme: neueFilme,
            neueSerien: neueSerien,
            gattungsreihen: gattungsreihen.map { .init(name: $0.name, items: $0.items) })
        Task.detached(priority: .utility) {
            guard let daten = try? ablage.daten() else { return }
            try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
            try? daten.write(to: ordner.appendingPathComponent(Startseitenablage.dateiname(konto: konto)),
                             options: .atomic)
        }
    }

    /// Beim Abmelden: der Stand eines Kontos, das nicht mehr auf dem Gerät
    /// ist, bleibt nicht liegen.
    static func ablageLoeschen(_ konto: String) {
        guard let ordner = ablageOrdner else { return }
        try? FileManager.default.removeItem(
            at: ordner.appendingPathComponent(Startseitenablage.dateiname(konto: konto)))
    }

    /// Zurück auf „noch nichts geladen" — die Seite zeigt ihre Platzhalter.
    private func leeren() {
        weiterschauen = []
        naechsteFolge = []
        zuletzt = []
        neueFilme = []
        neueSerien = []
        gattungsreihen = []
        bibliotheksreihen = []
        geladen = false
        gestoert = false
        zuletztGeladen = nil
        // Nach einem Kontowechsel oder Abmelden gilt wieder: was aus der
        // Ablage kommt, wird nebenher vom Server aufgefrischt.
        geladenVomServer = false
    }

    /// Muss beim Zurückkommen in den Vordergrund neu geholt werden?
    ///
    /// **Nicht, solange ein Lauf unterwegs ist.** Beim Kaltstart schlägt die
    /// Phase auf „aktiv", während der erste Lauf noch wartet — `zuletztGeladen`
    /// ist dann `nil`, also galt alles als fällig, und ein zweiter Lauf holte
    /// Bibliotheken und alle Reihen noch einmal. Gemessen am 25.09.2026 im
    /// tvOS-Simulator: bis zu fünf doppelte Anfragen je Start, der erste Lauf
    /// wurde verworfen. Der Mac hängt an derselben Frage
    /// (`didBecomeActiveNotification`).
    var brauchtAuffrischung: Bool {
        laufendeLaeufe == 0 && Auffrischung.faelligBeiRueckkehr(zuletzt: zuletztGeladen)
    }
}
