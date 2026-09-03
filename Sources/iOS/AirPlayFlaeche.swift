import AVKit
import SwiftUI

/// Der Abspieler für **echtes AirPlay** — `AVPlayer`, und nur dafür.
///
/// **Warum es einen zweiten Abspieler gibt.** AirPlay überträgt Bild
/// ausschließlich aus `AVPlayer`; libVLCs Fläche kennt es nicht. Der Weg
/// dahin ist gemessen und steht in `DeviceProfile.airplay()`: bei einer
/// passenden Datei liefert der Server sie unverändert aus (`DirectPlay`), bei
/// Matroska packt er den Container um — **ohne** Neuencode. Das Versprechen
/// der App bleibt also unangetastet, und was hierher kommt, hat
/// ``AirPlayEignung`` vorher freigegeben.
///
/// **Und warum `AVPlayerViewController` statt eigener Steuerung.** Er bringt
/// die Zielauswahl, Ton- und Untertitelspuren, Bild-im-Bild und die
/// Sperrbildschirmanzeige von Werk aus mit — und zwar in derselben Form, die
/// Zuschauer aus jeder anderen App kennen. Eine nachgebaute Steuerung wäre
/// mehr Code für ein schlechteres Ergebnis. Swiftlys eigene Steuerung bleibt
/// dem VLC-Weg vorbehalten, wo es keine Alternative gibt.
struct AirPlayFlaeche: UIViewControllerRepresentable {

    let url: URL
    let abSekunden: Double
    /// Stelle und Dauer, etwa jede Sekunde — fürs Melden an den Server.
    var stand: (Double, Double) -> Void
    var beendet: () -> Void
    /// **AVPlayers eigene Fehlermeldung.**
    ///
    /// Ohne sie ist ein Schwarzbild auf dem Fernseher nicht zu deuten — man
    /// sieht, dass nichts kommt, aber nicht woran es liegt. `errorLog()`
    /// nennt sogar den HTTP-Status des Segments, das gescheitert ist.
    var fehler: (String) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let spieler = AVPlayer(url: url)

        // **Das ist die Zeile, um die es hier geht.** Ohne sie überträgt
        // AirPlay nur den Ton — genau der Zustand, aus dem wir kommen.
        spieler.allowsExternalPlayback = true

        // Läuft schon eine Bildschirmsynchronisierung, soll trotzdem der
        // richtige Strom auf den Fernseher gehen und nicht das abgefilmte
        // Telefonbild.
        spieler.usesExternalPlaybackWhileExternalScreenIsActive = true

        if abSekunden > 1 {
            spieler.seek(to: CMTime(seconds: abSekunden, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        }

        let scheibe = AVPlayerViewController()
        scheibe.player = spieler
        scheibe.allowsPictureInPicturePlayback = true
        scheibe.canStartPictureInPictureAutomaticallyFromInline = true
        scheibe.videoGravity = .resizeAspect

        context.coordinator.anhaengen(an: spieler, scheibe: scheibe)
        spieler.play()
        return scheibe
    }

    /// Bewusst leer: der Abspieler wird **einmal** gebaut.
    ///
    /// Würde hier auf geänderte Werte reagiert, käme bei jedem Neuzeichnen der
    /// umgebenden Ansicht ein neues `AVPlayer`-Objekt heraus — und der Film
    /// begänne von vorn. Alles Veränderliche läuft über den Koordinator.
    func updateUIViewController(_ scheibe: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ scheibe: AVPlayerViewController,
                                          coordinator: Koordinator) {
        coordinator.aufraeumen()
        scheibe.player?.pause()
        scheibe.player = nil
    }

    func makeCoordinator() -> Koordinator {
        Koordinator(stand: stand, beendet: beendet, fehler: fehler)
    }

    /// **`@MainActor`, und die Rueckrufe heben einzeln.**
    ///
    /// `addPeriodicTimeObserver` verlangt einen `@Sendable`-Block, auch wenn
    /// man ihm `.main` als Warteschlange gibt. Ohne die Anhebung ist das ein
    /// Datenwettlauf im Typsystem — dieselbe Stelle, an der der
    /// Sperrbildschirm einmal mit „signal 5" abgebrochen ist. Siehe
    /// `Erfahrungen.md`, „`@MainActor` ist eine Zusicherung".
    @MainActor
    final class Koordinator {
        private let stand: (Double, Double) -> Void
        private let beendet: () -> Void
        private let fehler: (String) -> Void
        private var takt: Any?
        private var ende: NSObjectProtocol?
        private var schiefgegangen: NSObjectProtocol?
        private var protokolleintrag: NSObjectProtocol?
        private var zustand: NSKeyValueObservation?
        private weak var spieler: AVPlayer?

        init(stand: @escaping (Double, Double) -> Void, beendet: @escaping () -> Void,
             fehler: @escaping (String) -> Void) {
            self.stand = stand
            self.beendet = beendet
            self.fehler = fehler
        }

        func anhaengen(an spieler: AVPlayer, scheibe: AVPlayerViewController) {
            self.spieler = spieler

            // Jede Sekunde reicht: gemeldet wird an den Server, nicht
            // gezeichnet. Der Balken gehört hier `AVPlayerViewController`.
            takt = spieler.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                queue: .main
            ) { [weak self, weak spieler] zeit in
                MainActor.assumeIsolated {
                    guard let self, let spieler else { return }
                    let dauer = spieler.currentItem?.duration.seconds ?? 0
                    self.stand(zeit.seconds, dauer.isFinite ? dauer : 0)
                }
            }

            ende = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: spieler.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.beendet() }
            }

            guard let stueck = spieler.currentItem else { return }

            // **Drei Quellen, weil jede etwas anderes weiss.**
            //
            // `status` sagt, dass es scheiterte. `error` sagt grob warum.
            // `errorLog()` nennt die Adresse und den HTTP-Status des Segments
            // — und das ist die Angabe, aus der sich etwas ableiten laesst.
            zustand = stueck.observe(\.status, options: [.new]) { [weak self] stueck, _ in
                MainActor.assumeIsolated {
                    guard stueck.status == .failed else { return }
                    self?.melden("Status .failed", stueck.error)
                }
            }

            schiefgegangen = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: stueck, queue: .main
            ) { [weak self] nachricht in
                let grund = nachricht.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated { self?.melden("Abbruch", grund) }
            }

            protokolleintrag = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.newErrorLogEntryNotification,
                object: stueck, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let letzter = stueck.errorLog()?.events.last else { return }
                    let text = [
                        letzter.errorStatusCode != 0 ? "HTTP \(letzter.errorStatusCode)" : nil,
                        letzter.errorComment,
                        letzter.uri,
                    ].compactMap { $0 }.joined(separator: " · ")
                    Protokoll.schreib("[AirPlay] Protokolleintrag: \(text)")
                    self?.fehler(letzter.errorComment ?? "HTTP \(letzter.errorStatusCode)")
                }
            }
        }

        private func melden(_ woher: String, _ grund: (any Error)?) {
            let text = grund?.localizedDescription ?? "ohne Angabe"
            Protokoll.schreib("[AirPlay] \(woher): \(text)")
            fehler(text)
        }

        /// Wird von `dismantleUIViewController` gerufen — nicht aus `deinit`.
        /// Ein `deinit` ist nicht isoliert und darf hier nichts anfassen.
        func aufraeumen() {
            if let takt { spieler?.removeTimeObserver(takt) }
            takt = nil
            for b in [ende, schiefgegangen, protokolleintrag].compactMap({ $0 }) {
                NotificationCenter.default.removeObserver(b)
            }
            ende = nil; schiefgegangen = nil; protokolleintrag = nil
            zustand?.invalidate(); zustand = nil
        }
    }
}
