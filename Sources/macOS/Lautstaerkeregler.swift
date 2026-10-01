import AppKit
import SwiftUI

/// **Lautstärke im Player** — Lautsprecher-Knopf als erster der Symbolreihe;
/// beim Überfahren klappt links davon ein waagerechter Regler aus.
///
/// Maße wie im Entwurf: Fach 0 → 96 pt in 0,18 s (ease-out), Regler 88 pt,
/// Spur 4 pt, Griff 12 pt nur beim Überfahren oder Ziehen.
struct Lautstaerkeregler: View {
    let mass: Playermass
    /// 0 bis 1.
    @Binding var wert: Double
    /// Die Taste (Pfeile, M) hat den Regler kurz geöffnet.
    let aufgeklappt: Bool
    /// Zieht gerade jemand? Der Player blendet die Leiste dann nicht aus.
    @Binding var zieht: Bool
    let stummUmschalten: () -> Void
    /// Das Rad hat den Wert verstellt (Anteil von 0 bis 1, mit Vorzeichen).
    /// Der Player hält dann die Leiste und den Regler offen.
    let radGedreht: (Double) -> Void

    @State private var drueber = false
    @State private var radfang = Radfang()

    private var offen: Bool { drueber || zieht || aufgeklappt }

    private var symbol: String {
        if wert <= 0 { return "speaker.slash" }
        return wert < 0.5 ? "speaker.wave.1" : "speaker.wave.3"
    }

    var body: some View {
        HStack(spacing: 0) {
            Regler(wert: $wert, zieht: $zieht, hoehe: mass.knopf, gross: offen)
                .frame(width: 88)
                .padding(.horizontal, 4)
                .frame(width: offen ? 96 : 0, height: mass.knopf)
                .clipped()
                .opacity(offen ? 1 : 0)
                // **Prozent nur beim Verstellen**, unter dem Griff — außerhalb
                // von `clipped()`, sonst schnitte das Fach sie ab.
                .overlay(alignment: .bottomLeading) {
                    if zieht || aufgeklappt {
                        Text(verbatim: "\(Int((wert * 100).rounded())) %")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Stil.schriftLeise)
                            .frame(width: 44)
                            .offset(x: 4 + Self.griffX(wert, breite: 88) - 22, y: 14)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(Stil.bewegungReduziert ? nil : .easeOut(duration: 0.12), value: zieht || aufgeklappt)
            Symbolknopf(symbol: symbol,
                        beschriftung: wert <= 0 ? "Ton an" : "Ton aus",
                        mass: mass, aktion: stummUmschalten)
        }
        .onHover { innen in
            drueber = innen
            if innen { radfang.starten(radGedreht) } else { radfang.beenden() }
        }
        .onDisappear { radfang.beenden() }
        .animation(Stil.bewegungReduziert ? nil : .easeOut(duration: 0.18), value: offen)
        .accessibilityElement(children: .contain)
    }

    /// Mitte des Griffs. **Der Griff bleibt ganz in der Spur** — sein Weg
    /// endet einen Radius vor jedem Ende. Stand er bei 0 und 100 % mit der
    /// Hälfte darüber hinaus, schnitt ihn das Fach an einer harten Kante ab.
    static func griffX(_ wert: Double, breite: CGFloat) -> CGFloat {
        6 + (breite - 12) * CGFloat(min(max(wert, 0), 1))
    }

    /// **Mausrad und Zwei-Finger-Scrollen über Regler und Lautsprecher.**
    ///
    /// Ein Ereignisfänger statt einer Ansicht darüber: die läge über dem
    /// Regler und nähme ihm die Klicks. Er läuft nur, solange der Zeiger
    /// darüber steht, und **schluckt** das Ereignis — sonst scrollte darunter
    /// weiter, was das Rad sonst bekäme.
    ///
    /// `scrollingDeltaY` trägt die Systemrichtung schon in sich (natürliches
    /// Scrollen an oder aus), nach oben ist lauter. Ein Rad rastet: eine
    /// Raststufe sind 5 %, höchstens drei auf einmal. Ein Touchpad liefert
    /// Punkte: 24 Punkte sind 5 %, **ohne Runden**, damit kein kleiner Schub
    /// verschluckt wird.
    @MainActor
    final class Radfang {
        private var fang: Any?

        func starten(_ gedreht: @escaping (Double) -> Void) {
            guard fang == nil else { return }
            fang = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { ereignis in
                let d = Double(ereignis.scrollingDeltaY)
                guard d != 0 else { return nil }
                let schritt = ereignis.hasPreciseScrollingDeltas
                    ? d / 24 * 0.05
                    : min(max(d, -3), 3) * 0.05
                gedreht(schritt)
                return nil
            }
        }

        func beenden() {
            if let fang { NSEvent.removeMonitor(fang) }
            fang = nil
        }
    }

    private struct Regler: View {
        @Binding var wert: Double
        @Binding var zieht: Bool
        let hoehe: CGFloat
        let gross: Bool

        var body: some View {
            GeometryReader { geo in
                let breite = geo.size.width
                let x = Lautstaerkeregler.griffX(wert, breite: breite)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(Stil.akzent).frame(width: wert <= 0 ? 0 : x, height: 4)
                    Circle().fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(x: x - 6)
                        .opacity(gross ? 1 : 0)
                        .scaleEffect(gross ? 1 : 0.6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        zieht = true
                        wert = Double(min(max((g.location.x - 6) / max(breite - 12, 1), 0), 1))
                    }
                    .onEnded { _ in zieht = false })
            }
            .frame(height: hoehe)
            .accessibilityElement()
            .accessibilityLabel(Text("Lautstärke"))
            .accessibilityValue(Text("\(Int((wert * 100).rounded())) %"))
            .accessibilityAdjustableAction { richtung in
                switch richtung {
                case .increment: wert = min(wert + 0.05, 1)
                case .decrement: wert = max(wert - 0.05, 0)
                @unknown default: break
                }
            }
        }
    }
}
