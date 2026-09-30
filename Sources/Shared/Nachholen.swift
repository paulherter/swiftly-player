import SwiftUI

/// **Auffrischen nur, wo man hinsieht.**
///
/// Bereiche bleiben nach dem ersten Besuch mit Deckkraft 0 am Leben, und
/// Seiten im Stapel liegen unter der obersten. Jedes Wiedergabeende und jeder
/// Haken ließ vorher alle neu laden, auch die unsichtbaren — rund 30 Anfragen
/// nach jedem Player-Schließen, genau wenn die Endmeldung läuft (Audit
/// 29.09.2026). Jetzt merkt sich die verdeckte Seite, dass etwas fällig ist,
/// und holt es beim Zurückkommen nach.
private struct Nachholer: ViewModifier {
    let zaehler: Int
    /// Von außen: gilt zusätzlich zum Bereich und zur Sichtbarkeit.
    let vorn: Bool
    let tu: () -> Void

    @Environment(\.bereichAktiv) private var bereichAktiv
    /// Die Seite ist nicht von einer anderen im Stapel verdeckt.
    @State private var sichtbar = true
    /// Bis zu welchem Zählerstand die Seite auf dem Laufenden ist.
    @State private var erledigt: Int?

    private var aktiv: Bool { bereichAktiv && sichtbar && vorn }

    func body(content: Content) -> some View {
        content
            .onAppear {
                sichtbar = true
                if erledigt == nil { erledigt = zaehler }
            }
            .onDisappear { sichtbar = false }
            .onChange(of: zaehler) { _, neu in
                guard aktiv else { return }
                erledigt = neu
                tu()
            }
            .onChange(of: aktiv) { _, jetzt in
                guard jetzt, let erledigt, erledigt != zaehler else { return }
                self.erledigt = zaehler
                tu()
            }
    }
}

extension View {
    /// Ruft `tu`, wenn sich `zaehler` ändert und die Seite vorn liegt; sonst
    /// beim nächsten Vorkommen.
    func nachholen(bei zaehler: Int, vorn: Bool = true,
                   _ tu: @escaping () -> Void) -> some View {
        modifier(Nachholer(zaehler: zaehler, vorn: vorn, tu: tu))
    }
}
