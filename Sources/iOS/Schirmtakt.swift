import QuartzCore
import SwiftUI

/// **Misst, mit wie viel Hertz der Bildschirm diese App bedient.**
///
/// Nicht `UIScreen.maximumFramesPerSecond` -- das nennt, was die Hardware
/// koennte, und haette am 08.09.2026 auf einem iPhone 15 Pro brav 120
/// gemeldet, waehrend die App tatsaechlich auf 60 lief. iOS deckelt jede App
/// auf 60 Hz, solange sie `CADisableMinimumFrameDurationOnPhone` nicht setzt;
/// die Obergrenze der Hardware sagt darueber nichts.
///
/// Belastbar ist nur, wie oft CoreAnimation *uns* tatsaechlich ruft. Genau
/// das zaehlt diese Klasse -- ueber eine Sekunde, damit ein ausgelassener
/// Aufruf die Zahl nicht springen laesst.
///
/// Warum es das ueberhaupt gibt: 23,976 Bilder auf 60 Hz gehen nicht auf
/// (2,503), auf 120 Hz nahezu (5,005). Der Unterschied ist genau das
/// Ruckeln bei Schwenks -- und ohne diese Zahl bleibt die Frage, ob der
/// Deckel weg ist, Gefuehlssache.
@MainActor
@Observable
final class Schirmtakt {
    /// Gemessene Aufrufe je Sekunde. `nil`, solange die erste Sekunde laeuft.
    private(set) var hertz: Double?

    @ObservationIgnored private var glied: CADisplayLink?
    @ObservationIgnored private var seit: CFTimeInterval = 0
    @ObservationIgnored private var aufrufe = 0

    func starten() {
        guard glied == nil else { return }
        let ziel = Weiterleitung(besitzer: self)
        let neu = CADisplayLink(target: ziel, selector: #selector(Weiterleitung.schlag))
        // **Die Spanne muss angefordert werden.** Ohne sie laeuft der Zaehler
        // selbst auf der Voreinstellung und misst nicht den Schirm, sondern
        // die eigene Bescheidenheit.
        neu.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        neu.add(to: .main, forMode: .common)
        glied = neu
        seit = CACurrentMediaTime()
        aufrufe = 0
    }

    func anhalten() {
        glied?.invalidate()
        glied = nil
        hertz = nil
    }

    fileprivate func schlag() {
        aufrufe += 1
        let jetzt = CACurrentMediaTime()
        let spanne = jetzt - seit
        guard spanne >= 1 else { return }
        hertz = Double(aufrufe) / spanne
        seit = jetzt
        aufrufe = 0
    }

    /// `CADisplayLink` haelt sein Ziel fest. Ginge das direkt auf die Klasse,
    /// haette sie sich selbst am Leben gehalten, solange niemand `anhalten`
    /// ruft -- und ein vergessener Zaehler auf dem Hauptlauf ist genau die
    /// Sorte Last, die dieses Werkzeug messen soll.
    ///
    /// `@MainActor` ist hier keine Formsache: `CADisplayLink` ruft auf dem
    /// Hauptlauf, und ohne die Zusicherung verlangt Swift 6 einen Sprung
    /// ueber die Aktorgrenze, den es an einer `@objc`-Methode nicht geben
    /// kann.
    @MainActor
    private final class Weiterleitung: NSObject {
        weak var besitzer: Schirmtakt?
        init(besitzer: Schirmtakt) { self.besitzer = besitzer }
        @objc func schlag() { besitzer?.schlag() }
    }
}
