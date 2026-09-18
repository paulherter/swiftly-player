import Foundation
import JellyfinKit
import Observation

/// Der Ablauf hinter Quick Connect — Code holen, warten, freigegeben.
///
/// Stand vorher in `QuickConnectAnmeldung`, also in einer Ansicht, die nur
/// das iPhone übersetzt. Es ist aber kein Aussehen, sondern Ablauf: wie oft
/// gefragt wird, wie lange ein Code gilt, wie eine überholte Warteschleife
/// erkennt, dass sie überholt ist. Auf dem Fernseher gilt derselbe Ablauf —
/// dort ist Quick Connect sogar der wichtigere Weg, weil ein Kennwort mit
/// der Fernbedienung eine Zumutung ist.
///
/// Was die Ansicht danach tut, entscheidet sie selbst: das iPhone macht
/// erst das Blatt zu und meldet dann an, der Fernseher meldet direkt an.
@MainActor
@Observable
final class QuickConnectModell {
    private(set) var vorgang: Anmeldecode?
    private(set) var fehler: String?
    private(set) var restsekunden = Quickconnectfrist.sekunden
    /// Gesetzt, sobald jemand den Code freigegeben hat. Die Ansicht meldet
    /// damit an.
    private(set) var freigegeben: Anmeldecode?
    /// Am Server, der gerade hinzugefügt wird — statt an dem, mit dem die App
    /// verbunden ist. Siehe `ServerAufnahmeView`.
    var neuerServer = false

    /// Zählt hoch, wenn ein neuer Code geholt wird — ein überholter Start
    /// sieht daran, dass er überholt ist, und hört auf.
    private var lauf = 0
    /// Das laufende Warten. Wird beim Anhalten abgebrochen, damit keine
    /// Nachfrage mehr rausgeht und eine späte Freigabe niemanden anmeldet.
    private var warteaufgabe: Task<Void, Never>?

    func neuStarten(_ model: AppModel) async {
        anhalten()
        let meiner = lauf
        fehler = nil
        vorgang = nil
        freigegeben = nil
        restsekunden = Quickconnectfrist.sekunden
        do {
            let neu = try await (neuerServer ? model.quickConnectStartenAmNeuenServer()
                                             : model.quickConnectStarten())
            guard meiner == lauf else { return }
            vorgang = neu
            let aufgabe = Task { await warten(auf: neu, lauf: meiner, model: model) }
            warteaufgabe = aufgabe
            // `.task` der Ansicht bricht ab → das Warten auch.
            await withTaskCancellationHandler { await aufgabe.value }
                onCancel: { aufgabe.cancel() }
        } catch {
            guard meiner == lauf else { return }
            fehler = model.lesbar(error)
        }
    }

    /// **Der Ablauf steht im Paket** (`Quickconnectwarten`): Frist an der
    /// Uhr, Nachfrage im Takt und sofort nach der Rückkehr aus dem Browser,
    /// ein Netzfehler beendet das Warten nicht. Vorher brach hier der erste
    /// gescheiterte Abruf alles ab — auf dem iPhone genau beim Zurückkommen
    /// aus Safari, wenn die Verbindung im Hintergrund getrennt war.
    private func warten(auf vorgang: Anmeldecode, lauf meiner: Int, model: AppModel) async {
        let amNeuen = neuerServer
        let strom = Quickconnectwarten.ablauf {
            await (amNeuen ? model.quickConnectNachfragenAmNeuenServer(vorgang)
                           : model.quickConnectNachfragen(vorgang))
        }
        for await ereignis in strom {
            guard meiner == lauf, !Task.isCancelled else { return }
            switch ereignis {
            case let .rest(sekunden):
                restsekunden = sekunden
            case .freigegeben:
                lauf += 1
                freigegeben = vorgang
            case let .ende(letzte):
                restsekunden = 0
                fehler = Quickconnectfrist.schlusstext(letzte: letzte)
            }
        }
    }

    /// Hält eine laufende Warteschleife an — beim Schließen der Ansicht.
    func anhalten() {
        lauf += 1
        warteaufgabe?.cancel()
        warteaufgabe = nil
    }
}
