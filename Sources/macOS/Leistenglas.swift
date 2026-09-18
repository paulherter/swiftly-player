import AppKit
import SwiftUI

/// Die unscharfe Leiste hinter dem Detailkopf.
///
/// Wörtlich nach der iPhone-Fassung (`Unschaerfe` und `Leistenglas` in
/// `Sources/Shared/Stil.swift`), nur mit AppKit statt UIKit:
///
/// - **Das dünnste Material.** Jedes dickere hellt sichtbar auf. Dunkel wird
///   es nicht durch die Wahl des Materials, sondern durch den Grundton
///   darüber.
/// - **Geregelt wird über die Maske, nicht über `.opacity`.** Letzteres
///   schiebt die Ansicht in eine eigene Zeichenebene — dann hat sie keinen
///   Hintergrund mehr zu verwischen und die Leiste bleibt leer.
struct Unschaerfe: NSViewRepresentable {
    /// 0 bis 1.
    var staerke: Double = 1

    final class Ansicht: NSVisualEffectView {
        let maske = CALayer()

        override func layout() {
            super.layout()
            // Ohne das bleibt die Maske auf Größe null stehen und die ganze
            // Ansicht ist unsichtbar.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            maske.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Ansicht {
        let ansicht = Ansicht()
        ansicht.material = .hudWindow
        // **Im Fenster, nicht dahinter.** `.behindWindow` würde den
        // Schreibtisch verwischen; verwischt werden soll der Inhalt, der
        // darunter durchscrollt.
        ansicht.blendingMode = .withinWindow
        ansicht.state = .active
        ansicht.wantsLayer = true
        ansicht.layer?.mask = ansicht.maske
        setze(ansicht)
        return ansicht
    }

    func updateNSView(_ ansicht: Ansicht, context: Context) { setze(ansicht) }

    private func setze(_ ansicht: Ansicht) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ansicht.maske.backgroundColor =
            NSColor(white: 1, alpha: max(0, min(1, staerke))).cgColor
        CATransaction.commit()
    }
}

struct Leistenglas: View {
    var staerke: Double = 1
    /// Wie viel Grundton mit hineinspielt.
    var tiefe: Double = 0.5

    var body: some View {
        ZStack {
            Unschaerfe(staerke: staerke)
            Stil.grund.opacity(tiefe * staerke)
        }
        .allowsHitTesting(false)
    }
}
