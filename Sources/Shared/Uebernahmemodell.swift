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

    /// Was gerade angeboten wird — `nil`, wenn nichts läuft.
    private(set) var angebot: Fremdsitzung?

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
        angebot = nil
    }

    private func einmalFragen(_ model: AppModel) async {
        guard let client = model.client else { angebot = nil; return }
        let sitzungen = await client.fremdsitzungen()
        angebot = Uebernahme.angebot(aus: sitzungen,
                                     eigeneGeraeteID: AppModel.deviceID)
    }

    /// Das andere Gerät anhalten und hier weitermachen.
    ///
    /// **Erst anhalten, dann starten, und den Fehler nicht schlucken.** Läuft
    /// dort weiter, während hier dasselbe beginnt, stehen zwei Tonspuren im
    /// Raum und niemand versteht, warum. Geht das Anhalten schief, wird hier
    /// deshalb gar nicht gestartet.
    ///
    /// - Returns: Titel und Stelle, oder `nil` samt Meldung.
    func uebernehmen(_ model: AppModel) async -> (item: Item, ab: Double)? {
        guard let sitzung = angebot, let titel = sitzung.laeuft,
              let client = model.client, !uebernimmt else { return nil }
        uebernimmt = true
        defer { uebernimmt = false }

        do {
            try await client.fremdbefehl(.anhalten, an: sitzung.id)
        } catch {
            fehler = error.localizedDescription
            return nil
        }

        // Die Stelle vom anderen Gerät, nicht vom Server-Fortschritt: sie ist
        // sekundengenau und die Meldung ans Konto hinkt bis zu zehn Sekunden
        // nach.
        let ab = sitzung.stand?.stelle ?? 0
        // Damit das Abzeichen nicht noch einen Takt lang stehenbleibt.
        angebot = nil
        return (titel, ab)
    }
}
