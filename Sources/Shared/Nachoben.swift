import SwiftUI

/// Scrollt eine Liste nach oben — in zwei Fällen, ein Baustein:
///
/// - **Die Ordnung wechselt** (`ordnung`: Sortierung, Filter, Gattung). Wer
///   300 Titel tief ist, bekommt sonst die neue Reihenfolge an der alten
///   Stelle.
/// - **Zweiter Tipp auf den Reiter**, in dem man schon ist (`nochmal`, siehe
///   `reiterNochmal`), solange der Bereich sichtbar ist (`aktiv`).
///
/// Der Wert beim Aufbau löst nichts aus. Nur eine `scrollPosition` je
/// Scrollfläche, deshalb beide Anlässe in einem Baustein.
private struct NachObenModifier: ViewModifier {
    let ordnung: String
    let nochmal: Int
    let aktiv: Bool
    @State private var stelle = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($stelle)
            .onChange(of: ordnung) { _, _ in
                stelle.scrollTo(edge: .top)
            }
            .onChange(of: nochmal) { _, _ in
                guard aktiv else { return }
                withAnimation(Stil.umschalten) { stelle.scrollTo(edge: .top) }
            }
    }
}

extension View {
    /// An die `ScrollView` hängen (oder an einen Vorfahren).
    func nachOben(ordnung: String = "", nochmal: Int = 0, aktiv: Bool = true) -> some View {
        modifier(NachObenModifier(ordnung: ordnung, nochmal: nochmal, aktiv: aktiv))
    }
}
