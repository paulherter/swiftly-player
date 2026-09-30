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

    @State private var drueber = false

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
        .onHover { drueber = $0 }
        .animation(Stil.bewegungReduziert ? nil : .easeOut(duration: 0.18), value: offen)
        .accessibilityElement(children: .contain)
    }

    /// Mitte des Griffs. **Der Griff bleibt ganz in der Spur** — sein Weg
    /// endet einen Radius vor jedem Ende. Stand er bei 0 und 100 % mit der
    /// Hälfte darüber hinaus, schnitt ihn das Fach an einer harten Kante ab.
    static func griffX(_ wert: Double, breite: CGFloat) -> CGFloat {
        6 + (breite - 12) * CGFloat(min(max(wert, 0), 1))
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
