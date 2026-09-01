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
    private(set) var restsekunden = 300
    /// Gesetzt, sobald jemand den Code freigegeben hat. Die Ansicht meldet
    /// damit an.
    private(set) var freigegeben: Anmeldecode?

    /// Zählt hoch, wenn ein neuer Code geholt wird — die alte Warteschleife
    /// sieht daran, dass sie überholt ist, und hört auf.
    private var lauf = 0

    func neuStarten(_ model: AppModel) async {
        lauf += 1
        let meiner = lauf
        fehler = nil
        vorgang = nil
        freigegeben = nil
        restsekunden = 300
        do {
            let neu = try await model.quickConnectStarten()
            guard meiner == lauf else { return }
            vorgang = neu
            await warten(auf: neu, lauf: meiner, model: model)
        } catch {
            guard meiner == lauf else { return }
            fehler = model.lesbar(error)
        }
    }

    /// Die Uhr läuft im Sekundentakt, gefragt wird jede zweite Sekunde.
    ///
    /// Jellyfin bietet für Quick Connect keinen Rückkanal an, es bleibt beim
    /// Nachfragen. Jede Sekunde wären über fünf Minuten dreihundert Anfragen
    /// für nichts; zwei Sekunden merkt niemand, und die Restzeit läuft
    /// trotzdem sichtbar weiter.
    private func warten(auf vorgang: Anmeldecode, lauf meiner: Int, model: AppModel) async {
        while restsekunden > 0 {
            try? await Task.sleep(for: .seconds(1))
            guard meiner == lauf, !Task.isCancelled else { return }
            restsekunden -= 1
            guard restsekunden % 2 == 0 else { continue }
            do {
                if try await model.quickConnectFreigegeben(vorgang) {
                    guard meiner == lauf else { return }
                    lauf += 1
                    freigegeben = vorgang
                    return
                }
            } catch {
                guard meiner == lauf else { return }
                lauf += 1
                fehler = model.lesbar(error)
                return
            }
        }
        fehler = String(localized: "Der Code ist abgelaufen. Hol dir einen neuen.")
    }

    /// Hält eine laufende Warteschleife an — beim Schließen der Ansicht.
    func anhalten() { lauf += 1 }
}
