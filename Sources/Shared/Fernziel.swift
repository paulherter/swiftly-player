#if os(iOS)
import AVFoundation
import Foundation

/// Beobachtet, **wohin** der Ton geht — und meldet, wenn das ein AirPlay-Gerät
/// ist.
///
/// **Warum das der Auslöser ist und kein Knopf.** Paul: „ich geh bei meinem
/// iPhone oben auf Ziel ändern und änder von iPhone → Apple TV." Das ist der
/// Weg, den Leute kennen, und er ist einen Griff kürzer als jeder Knopf, den
/// man in einer Steuerung erst finden muss. Swiftly muss den Wechsel also
/// nicht anbieten, sondern nur **bemerken** und das Bild hinterherschieben.
///
/// **Der Ton wechselt von selbst, das Bild nicht.** Die Systemtonsitzung folgt
/// dem neuen Ziel ohne unser Zutun — deshalb hörte Paul bisher schon etwas.
/// Bild überträgt AirPlay nur aus `AVPlayer`; libVLCs Fläche kennt es nicht.
/// Genau diese Lücke schließt die Meldung hier.
///
/// Sie hängt an derselben Systemmeldung wie die Bluetooth-Behandlung in
/// ``Wiedergabezentrale``, ist aber ein eigenes Objekt: dort geht es darum,
/// den Tonausgang neu aufzubauen, hier darum, den **Abspieler zu tauschen**.
/// Zwei Beobachter auf einer Meldung sind billiger als eine Klasse, die zwei
/// Dinge tut.
@MainActor
final class Fernziel {

    /// Läuft der Ton gerade über AirPlay?
    private(set) var aufAirPlay: Bool

    /// Name des Ziels, wie es in der Zielauswahl steht — „Wohnzimmer".
    private(set) var zielname: String?

    /// Wird gerufen, wenn sich das geändert hat. Nicht bei jedem Routenwechsel:
    /// nur beim Übergang, sonst würde jeder Kopfhörerwechsel den Abspieler
    /// tauschen.
    var gewechselt: ((Bool) -> Void)?

    private var beobachter: NSObjectProtocol?

    init() {
        let stand = Self.stand()
        aufAirPlay = stand.airplay
        zielname = stand.name
        beobachter = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            // `Notification` ist nicht `Sendable`; hier wird ohnehin nichts
            // daraus gebraucht — der Stand steht in der Sitzung selbst.
            MainActor.assumeIsolated { self?.nachsehen() }
        }
    }

    /// **Kein `deinit`.** Ein `deinit` ist nicht isoliert und darf den
    /// Beobachter nicht mehr anfassen — dieselbe Swift-6-Regel, die den
    /// Sperrbildschirm einmal mit „signal 5" beendet hat. Wer aufhoert, sagt
    /// es also selbst; der Rueckruf haelt `self` ohnehin nur schwach.
    func aufhoeren() {
        gewechselt = nil
        if let beobachter { NotificationCenter.default.removeObserver(beobachter) }
        beobachter = nil
    }

    /// Auch von Hand aufrufbar — beim Öffnen des Players, weil das Ziel dann
    /// schon auf dem Fernseher stehen kann.
    func nachsehen() {
        let stand = Self.stand()
        zielname = stand.name
        guard stand.airplay != aufAirPlay else { return }
        aufAirPlay = stand.airplay
        Protokoll.schreib("[Ziel] \(stand.airplay ? "AirPlay" : "Gerät") — \(stand.name ?? "?")")
        gewechselt?(stand.airplay)
    }

    /// **Der Ausgang zählt, nicht der Grund.**
    ///
    /// `AVAudioSession.RouteChangeReason` sagt bei einem Zielwechsel je nach
    /// Weg `.override`, `.categoryChange` oder `.routeConfigurationChange` —
    /// darauf zu unterscheiden wäre geraten. Die Frage „geht der Ton auf ein
    /// AirPlay-Gerät" beantwortet die Route selbst, eindeutig.
    private static func stand() -> (airplay: Bool, name: String?) {
        let ausgaenge = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let fern = ausgaenge.first(where: { $0.portType == .airPlay }) else {
            return (false, ausgaenge.first?.portName)
        }
        return (true, fern.portName)
    }
}
#endif
