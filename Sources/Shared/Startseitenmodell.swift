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

    /// Zu welchem Kontostand der Inhalt gehört.
    private var fuerKonto = 0

    var alleLeer: Bool {
        weiterschauen.isEmpty && naechsteFolge.isEmpty
            && zuletzt.isEmpty && neueFilme.isEmpty && neueSerien.isEmpty
    }

    func laden(_ model: AppModel) async {
        // **Zu welchem Konto dieser Lauf gehört.** Erst beim Übernehmen
        // unten wird daraus etwas — hier wird nichts geleert.
        //
        // Das war mein erster Versuch, und er hat den Fehler nur verschoben:
        // die Seite vorweg leerzuräumen nimmt sämtliche Kacheln vom Schirm,
        // und mit ihnen bricht jede laufende Bildladung ab. Gemessen am
        // Gerät, zwanzigmal in Folge: `NSURLErrorDomain -999`, also
        // „abgebrochen" — nicht abgelehnt, nicht verfehlt. Auch die Kacheln,
        // die gleich darauf neu entstanden, gerieten noch in den Abbruch.
        let diesesKonto = model.kontowechsel
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
        // **Beim Wechsel wird ersetzt, nicht ergänzt.** Sonst bliebe stehen,
        // was nicht geantwortet hat — und das gehörte dem vorigen Konto.
        // Ohne Wechsel gilt weiter: ein einzelner Aussetzer darf die Seite
        // nicht leerräumen.
        let wechsel = diesesKonto != fuerKonto
        fuerKonto = diesesKonto

        // **Jede Reihe geht entdoppelt hinein.**
        //
        // `ForEach` ordnet seine Zeilen ueber die Kennung zu; bei zwei
        // gleichen greift ein Tipp daneben. Am 07.09.2026 gemeldet: auf
        // „Zuletzt hinzugefuegt" oeffnete ein Druck auf eine Serie die
        // uebernaechste. Bibliothek und Merkliste hatten die Regel je fuer
        // sich, weil dort geblaettert wird — hier fehlte sie, weil eine Reihe
        // aus einem einzigen Abruf kommt und ein Abruf nichts doppelt
        // liefern sollte. Ein Server mit durcheinandergeratener Bibliothek
        // tut es doch. Die Regel steht jetzt einmal im Paket.
        if let a { weiterschauen = Listenregeln.ohneDoppelte(a) }
        else if wechsel { weiterschauen = [] }
        if let b { naechsteFolge = Listenregeln.ohneDoppelte(b) }
        else if wechsel { naechsteFolge = [] }
        // **Die nicht gewaehlte Form wird geleert, nicht bloss nicht
        // geholt.** Sonst bliebe die Reihe von vorhin stehen: wer umschaltet,
        // saehe „Zuletzt hinzugefuegt" **und** die beiden neuen. Genau das
        // ist beim ersten Versuch passiert.
        if getrennt {
            zuletzt = []
            if let d { neueFilme = Listenregeln.ohneDoppelte(d) }
            else if wechsel { neueFilme = [] }
            if let e { neueSerien = Listenregeln.ohneDoppelte(e) }
            else if wechsel { neueSerien = [] }
        } else {
            neueFilme = []
            neueSerien = []
            if let c { zuletzt = Listenregeln.ohneDoppelte(c) }
            else if wechsel { zuletzt = [] }
        }

        // Ein Abbruch ist kein Ausfall — dieselbe Unterscheidung wie in
        // `Bibliotheksmodell`.
        // Bei getrennten Reihen zählen die beiden statt der einen.
        let neuesDa = getrennt ? (d != nil || e != nil) : c != nil
        gestoert = !Task.isCancelled && a == nil && b == nil && !neuesDa
        if !gestoert { zuletztGeladen = Date() }
        geladen = true

        // **Die Serien zu den Folgen im Hintergrund nachziehen.**
        //
        // „Weiterschauen" und „Naechste Folge" sind Folgen, keine Serien; ein
        // Druck darauf fuehrt ueber `StaffelZiel` auf die Serienseite, und die
        // braucht erst einmal die Serie selbst (A8). Bis sie da war, fuhr eine
        // leere Seite herein — auf dem Mac gemessene 92 bis 174 ms.
        //
        // **Hier statt in jeder Startseite.** Der Mac hatte die Zeile in
        // seiner `HomeView`, der Fernseher und das iPhone nicht. Sie gehoert
        // dorthin, wo die Reihen entstehen: dann bekommt jede Plattform sie
        // dadurch, dass sie dieses Modell benutzt, und keine kann sie
        // vergessen. Doppelt aufgerufen kostet es nichts — `vorholen` haelt
        // fest, was schon bekannt ist und was gerade laeuft.
        Serienspeicher.geteilt.vorholen(weiterschauen + naechsteFolge + neueSerien,
                                        mit: model)
    }

    /// Muss beim Zurückkommen in den Vordergrund neu geholt werden?
    var brauchtAuffrischung: Bool {
        Auffrischung.faelligBeiRueckkehr(zuletzt: zuletztGeladen)
    }
}
