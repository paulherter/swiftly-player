import SwiftUI

// MARK: - Übergänge
//
// Feder und Karte aus dem Abzeichen — iPhone, iPad, Mac und Fernseher. Die Farbe
// aus dem Bild steht in `Bildstimmung.swift` (iPhone) bzw. `Bildton.swift`.

extension Stil {
    /// **Die Feder für alles, was auf- und zugeht.** Kritisch gedämpft
    /// genug, dass nichts nachschwingt (0,9), schnell genug, dass es auf den
    /// Finger antwortet (0,35). Eine Feder statt einer Dauer: wer mitten im
    /// Öffnen wieder schließt, lenkt die Bewegung um, statt sie von vorn
    /// beginnen zu sehen. Mit reduzierter Bewegung die kurze Überblendung.
    static var feder: Animation {
        bewegungReduziert ? blendeReduziert : .spring(response: 0.35, dampingFraction: 0.9)
    }
}

// MARK: - Aus einem Punkt heraus

/// **Eine Karte, die aus ihrem Knopf wächst** und dorthin zurückschrumpft.
///
/// Der Punkt ist in globalen Koordinaten gegeben; wo er relativ zur Karte
/// liegt, rechnet `visualEffect` aus dem Rahmen, den die Karte gerade hat —
/// ohne dass sie ihr Layout dafür ändert. Nur Maßstab und Deckkraft ändern
/// sich, beides ohne neues Layout je Bild.
struct Herkunftsauftritt: ViewModifier {
    /// 0 = im Punkt, 1 = da.
    let anteil: Double
    let ursprung: CGPoint?

    /// So groß wie das Abzeichen im Verhältnis zu einer Karte von rund 360.
    nonisolated private static let anfang: CGFloat = 0.12

    func body(content: Content) -> some View {
        content
            .visualEffect { [anteil, ursprung] inhalt, lage in
                let rahmen = lage.frame(in: .global)
                let anker = ursprung.map {
                    UnitPoint(x: ($0.x - rahmen.minX) / max(rahmen.width, 1),
                              y: ($0.y - rahmen.minY) / max(rahmen.height, 1))
                } ?? .center
                let mass = Self.anfang + (1 - Self.anfang) * CGFloat(anteil)
                return inhalt.scaleEffect(mass, anchor: anker)
            }
            // Die Deckkraft läuft schneller als der Maßstab: ganz klein ist
            // die Karte fast unsichtbar, und beim Schließen ist sie weg,
            // bevor sie zum Punkt wird.
            .opacity(min(1, anteil * 1.6))
    }
}

extension AnyTransition {
    /// Wächst aus `ursprung` (global) heraus; ohne Punkt oder mit reduzierter
    /// Bewegung schlicht überblendet.
    static func ausDemPunkt(_ ursprung: CGPoint?) -> AnyTransition {
        guard ursprung != nil, !Stil.bewegungReduziert else { return .opacity }
        return .modifier(active: Herkunftsauftritt(anteil: 0, ursprung: ursprung),
                         identity: Herkunftsauftritt(anteil: 1, ursprung: ursprung))
    }
}

/// **Wo das zuletzt gedrückte Abzeichen steht**, in globalen Koordinaten
/// (Versuch `experiment-glas`). Die Auswahl wächst von dort heraus und
/// schrumpft dorthin zurück. Es gibt mehrere Abzeichen im Baum — je Seite
/// eins —, gemeint ist immer das, das den Tipp bekam; deshalb gesetzt beim
/// Tippen und nicht über eine Vorgabe aus dem Baum. Auf dem Fernseher gibt
/// es nur das eine in der Kopfleiste; es meldet seinen Rahmen laufend.
@MainActor
enum Abzeichenursprung {
    static var punkt: CGPoint?
}

// Der Kontowechsel (Ablauf, Kurve, gestaffelte Reihen) steht in
// `Sources/Shared/Kontowechselflug.swift` — alle Apple-Plattformen teilen
// ihn; Bühne und Selbsttest in UIKit in `KontowechselbuehneUIKit.swift`.
