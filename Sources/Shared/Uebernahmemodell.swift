import Foundation
import JellyfinKit
import Observation

/// Hält nach, ob auf einem anderen Gerät gerade etwas läuft.
///
/// **Warum ein eigener Halter und nicht ein `.task` in der Ansicht.** Die
/// Frage stellt sich auf allen vier Plattformen, das Abzeichen sieht überall
/// gleich aus, und die Regel dahinter steckt in ``Uebernahme`` im Paket. Was
/// hier liegt, ist nur das Abfragen im Takt — und das gehört nicht in eine
/// Ansicht, die bei jedem Neuzeichnen von vorn beginnen würde.
///
/// Wie ``Startseitenmodell`` und ``Bibliotheksmodell``.
@MainActor
@Observable
final class Uebernahmemodell {

    /// Alles, was übernommen werden kann — jüngste Regung zuerst.
    private(set) var angebote: [Fremdsitzung] = []

    /// Das erste davon, für den Fall, dass es nur eins gibt.
    var angebot: Fremdsitzung? { angebote.first }

    /// Mehr als eins? Dann fragt die Oberfläche, statt zu raten.
    var mehrereDa: Bool { angebote.count > 1 }

    /// Was schiefging — für eine Meldung in der Ansicht.
    var fehler: String?

    /// Läuft die Übernahme gerade? Sperrt den Knopf, damit ein zweiter Druck
    /// nicht zwei Wiedergaben startet.
    private(set) var uebernimmt = false

    private var takt: Task<Void, Never>?

    /// **Zehn Sekunden.**
    ///
    /// Der Fortschrittsbericht der anderen Seite kommt in demselben Takt, ein
    /// schnelleres Fragen erfährt also nichts Neues. Und es ist eine Abfrage,
    /// die läuft, solange jemand auf der Startseite steht — sie darf den
    /// Server nicht beschäftigen.
    static let taktsekunden: Double = 10

    func starten(_ model: AppModel) {
        guard takt == nil else { return }
        takt = Task { [weak self] in
            while !Task.isCancelled {
                await self?.einmalFragen(model)
                try? await Task.sleep(for: .seconds(Self.taktsekunden))
            }
        }
    }

    func beenden() {
        takt?.cancel()
        takt = nil
        angebote = []
    }

    private func einmalFragen(_ model: AppModel) async {
        // `model.session` statt `client.currentSession()`: der Client ist ein
        // Aktor, die Sitzung liegt hier ohnehin schon auf dem Hauptakteur.
        guard let client = model.client,
              let benutzer = model.session?.userID else { angebote = []; return }
        let sitzungen = await client.fremdsitzungen()
        angebote = Uebernahme.angebote(aus: sitzungen,
                                       eigeneGeraeteID: AppModel.deviceID,
                                       eigeneBenutzerID: benutzer)
    }

    /// Das andere Gerät anhalten und hier weitermachen.
    ///
    /// **Erst drüben beenden, dann hier starten, und den Fehler nicht
    /// schlucken.** Läuft dort weiter, während hier dasselbe beginnt, stehen
    /// zwei Tonspuren im Raum und niemand versteht, warum. Geht es schief,
    /// wird hier deshalb gar nicht gestartet.
    ///
    /// **Beenden, nicht anhalten.** Pausiert bleibt die Verbindung zum Server
    /// offen, die Sitzung steht weiter in der Übersicht, und auf dem anderen
    /// Gerät liegt noch der Player über allem — man müsste ihn von Hand
    /// schließen. Paul: „der Stream aufm Handy muss geschlossen werden, nicht
    /// nur pausiert." Die Stelle ist vorher gelesen, sie geht dabei nicht
    /// verloren.
    ///
    /// - Returns: Titel und Stelle, oder `nil` samt Meldung.
    /// - Parameter sitzung: Welche übernommen werden soll. Bei mehreren hat
    ///   die Oberfläche gefragt; bei einer ist es schlicht die eine.
    func uebernehmen(_ sitzung: Fremdsitzung, model: AppModel) async -> (item: Item, ab: Double)? {
        guard let titel = sitzung.laeuft,
              let client = model.client, !uebernimmt else { return nil }
        uebernimmt = true
        defer { uebernimmt = false }

        do {
            try await client.fremdbefehl(.beenden, an: sitzung.id)
        } catch {
            fehler = error.localizedDescription
            return nil
        }

        // Die Stelle vom anderen Gerät, nicht vom Server-Fortschritt: sie ist
        // sekundengenau und die Meldung ans Konto hinkt bis zu zehn Sekunden
        // nach. Sie stammt aus der Abfrage **vor** dem Beenden — was das
        // andere Gerät beim Schließen meldet, kommt hier zu spät an.
        let ab = sitzung.stand?.stelle ?? 0
        // Damit das Abzeichen nicht noch einen Takt lang stehenbleibt.
        angebote = []
        return (titel, ab)
    }

    /// Dasselbe, aber gleich als fertiger ``Abspielwunsch``.
    ///
    /// **Warum das hier steht und nicht in den Ansichten.** Diese sechs
    /// Zeilen standen zeichengleich in `Sources/tvOS/HauptView.swift` und
    /// `Sources/Shared/HomeView.swift` — von mir selbst, am selben
    /// Nachmittag, beim Übertragen der Übernahme von einer Plattform auf die
    /// andere. Byte für Byte identisch ist genau der Fall, vor dem CLAUDE.md
    /// warnt; die tvOS-Sitzung hat ihn im Tiefendurchgang gefunden.
    ///
    /// **macOS benutzt es nicht, und das ist richtig so.** Dort startet die
    /// Wiedergabe über ``Abspielsteuerung``, die den Plan selbst holt — ein
    /// echter Unterschied im Aufbau, keine Abweichung aus Versehen.
    func wunsch(fuer sitzung: Fremdsitzung, model: AppModel) async -> Abspielwunsch? {
        guard let (titel, ab) = await uebernehmen(sitzung, model: model),
              let plan = await model.plan(for: titel.id) else { return nil }
        return Abspielwunsch(item: titel, plan: plan, startAt: ab)
    }
}

/// Wie eine fremde Sitzung benannt und bebildert wird.
///
/// **Geteilt, nicht je Plattform.** Fernseher, Telefon und Mac zeigen
/// dasselbe Abzeichen; eine zweite Fassung davon liefe innerhalb einer Woche
/// auseinander. Genau der Fall, den CLAUDE.md meint.
extension Fremdsitzung {
    /// „Game of Thrones · S1 E5" oder schlicht der Filmtitel.
    ///
    /// Serverdaten, also `String` und nicht `LocalizedStringKey`: sonst
    /// würde ein Filmtitel als Übersetzungsschlüssel nachgeschlagen.
    /// **Liegt jetzt im Paket** (``Fremdsitzung/titelzeile``). Sie hing hier
    /// und war fuer die Linux-Fassung unerreichbar; dort stand deshalb eine
    /// eigene, kuerzere Zusammensetzung.

    /// Das Symbol zum Geraet. **Welches Geraet** es ist, entscheidet
    /// ``Fremdsitzung/geraeteart`` im Paket — die Zuordnung darf nicht
    /// auseinanderlaufen. Welches *Zeichen* dafuer steht, bleibt Sache der
    /// Plattform: hier SF Symbols, auf Linux Adwaita.
    var geraetezeichen: String {
        switch geraeteart {
        case .telefon:   "iphone"
        case .tablet:    "ipad"
        case .rechner:   "laptopcomputer"
        case .fernseher: "tv"
        case .unbekannt: "play.tv"
        }
    }
}

