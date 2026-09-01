import AppKit
import SwiftUI

/// Nimmt der Titelleiste ihr eigenes Material.
///
/// `.windowStyle(.hiddenTitleBar)` blendet nur den **Titel** aus; die Leiste
/// selbst bleibt und legt ein helles Systemmaterial über den Inhalt. Dann
/// steht oben ein aufgehellter Streifen, während überall sonst in dieser App
/// der Inhalt unter Kopf und Leiste **durchläuft**.
///
/// Drei Angaben braucht es: die Leiste durchsichtig, den Fenstergrund auf
/// unseren Grundton (sonst blitzt Apples Fensterweiß beim Größenändern durch)
/// und den vollen Inhaltsbereich, damit er bis unter die Ampel reicht.
struct Fensteranstrich: NSViewRepresentable {

    final class Spion: NSView {
        private var beobachter: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            anstreichen()

            // **Einmal anstreichen genügt nicht.** AppKit und SwiftUI setzen
            // Leiste und Material bei Gelegenheit neu — beim Vollbildwechsel
            // und wenn das Fenster wieder nach vorn kommt. Der Anstrich lief
            // dann ins Leere gesetzter Zustand gegen neu gebaute Ansichten,
            // und die helle Leiste war zurück.
            //
            // Dieselbe Form wie der Ampelfehler: die anwendende Stelle muss
            // dort noch einmal laufen, wo sich die Vorbedingung ändert.
            // Beim Verlassen des Fensters die alten Beobachter lösen — sonst
            // sammeln sie sich, wenn die Ansicht mehrfach umzieht.
            beobachter.forEach(NotificationCenter.default.removeObserver)
            beobachter.removeAll()
            guard let fenster = window else { return }
            for name: Notification.Name in [NSWindow.didBecomeKeyNotification,
                                            NSWindow.didEnterFullScreenNotification,
                                            NSWindow.didExitFullScreenNotification] {
                beobachter.append(NotificationCenter.default.addObserver(
                    forName: name, object: fenster, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.anstreichen() }
                    })
            }
        }

        private func anstreichen() {
            guard let fenster = window else { return }
            fenster.titlebarAppearsTransparent = true
            fenster.titleVisibility = .hidden
            fenster.backgroundColor = NSColor(Stil.grund)
            fenster.isOpaque = true
            fenster.styleMask.insert(.fullSizeContentView)

            // **`titlebarAppearsTransparent` allein genügt nicht.** Die Leiste
            // behält ihr eigenes Material und hellt auf, auch wenn der Inhalt
            // darunter durchläuft — dieselbe Sache wie bei
            // `.ultraThinMaterial`: jedes Material trägt eine helle Schicht.
            //
            // Drei Dinge müssen weg: eine gesetzte Werkzeugleiste, der
            // Trennstrich, und das Material in der Leiste selbst.
            fenster.toolbar = nil
            fenster.titlebarSeparatorStyle = .none

            // Die Leiste ist die Elternansicht der Fensterampel. Was darin
            // ein `NSVisualEffectView` ist, ist die helle Schicht.
            if let leiste = fenster.standardWindowButton(.closeButton)?.superview {
                materialAusblenden(in: leiste)
            }
        }

        /// Sucht in der Leiste nach Materialflächen und stellt sie still.
        /// Nur öffentliche `NSView`-Mittel: was gefunden wird, bekommt
        /// `.clear` als Zustand — ausblenden würde auch die Ampel mitnehmen,
        /// die in derselben Ansicht sitzt.
        private func materialAusblenden(in ansicht: NSView) {
            for teil in ansicht.subviews {
                if let material = teil as? NSVisualEffectView {
                    material.material = .windowBackground
                    material.blendingMode = .withinWindow
                    material.state = .inactive
                    material.isHidden = true
                }
                materialAusblenden(in: teil)
            }
        }
    }

    func makeNSView(context: Context) -> Spion { Spion(frame: .zero) }
    func updateNSView(_ ansicht: Spion, context: Context) {}
}
