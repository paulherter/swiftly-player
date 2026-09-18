import SwiftUI
import UIKit

// Wenn iPadOS seine Knöpfe auf unser Fenster legt.
//
// **Eigene Datei, und das ist der Punkt.** Das hier stand in
// `Heldkopf.swift`, weil es beim Bau der Detailseite gebraucht wurde — dabei
// hängt inzwischen fast jede Kopfzeile daran: `Seitenleiste`,
// `Unschaerfekopf`, `Detailkopf`, `Seitenpfeil`, `HauptView`, `HomeView`,
// `SucheView` und beide Player. Wer die Ampel sucht, sucht sie nicht im
// Heldenbild.

private struct FensterknoepfeSchluessel: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// iPadOS legt eigene Fensterknöpfe über die obere linke Ecke.
    ///
    /// Sobald die App sich den Schirm teilt — geteilter Bildschirm, Stage
    /// Manager —, setzt iPadOS seine Ampel auf das Fenster. Genau dort sitzt
    /// unser Zurückpfeil: `Seitenpfeil` hält 8 Punkt von links und 6 von
    /// oben. Im Vollbild schiebt ihn die Statusleiste nach unten, in einem
    /// Fenster gibt es die nicht — und die Knöpfe decken ihn zu.
    ///
    /// Erkannt wird es an der Breite, nicht an der Größenklasse: „teilt sich
    /// den Schirm" heißt genau, dass das Fenster schmaler ist als der Schirm.
    /// Slide Over, halber und Zweidrittel-Schirm fallen alle darunter,
    /// Vollbild nicht.
    var fensterknoepfe: Bool {
        get { self[FensterknoepfeSchluessel.self] }
        set { self[FensterknoepfeSchluessel.self] = newValue }
    }
}


/// Wo iPadOS seine Fensterknöpfe hinlegt, und wie viel Platz sie brauchen.
///
/// **Warum das eine Funktion ist und nicht nur der Umgebungswert oben:** der
/// Player ist ein `fullScreenCover`. Er hängt nicht unter `HauptView`, und
/// er ignoriert den sicheren Bereich ausdrücklich — dort liegt schließlich
/// das Bild. Ein Sicherheitsabstand, den sich der Rahmen nimmt, erreicht ihn
/// deshalb nicht. Was im Player oben Platz braucht, muss ihn sich selbst
/// nehmen.
///
/// Genau daran ist die erste Fassung gescheitert: sie hat den Rahmen
/// gepolstert und den Player vergessen, weil er wie ein Teil davon aussieht.
enum Fensterknoepfe {
    /// Höhe, die freizuhalten ist. Die Ampel sitzt in einem rund 44 Punkt
    /// hohen Feld oben links; 32 zusätzlich zu den 18, die die Kopfzeilen
    /// ohnehin halten, schiebt den Knopf darunter.
    static let hoehe: CGFloat = 32

    /// Die App liegt in einem Fenster statt im Vollbild.
    ///
    /// **Am Gerät gemessen, nicht hergeleitet.** Zwei Annahmen waren vorher
    /// falsch, und beide klangen plausibel:
    ///
    /// - „Ein Fenster hat keine Statusleiste, also keinen oberen sicheren
    ///   Bereich." Falsch. Gemessen sind es in **beiden** Fällen 32 Punkt —
    ///   der sichere Bereich unterscheidet gar nichts.
    /// - „Ein Fenster meldet seinen eigenen Schirm." Ebenfalls falsch.
    ///   `screen.bounds.width` meldet 1180, während das Fenster 375 misst.
    ///
    /// Der Breitenvergleich stimmt also. Was nicht stimmte, war die Annahme,
    /// ein Sicherheitsabstand am Rahmen erreiche alle — siehe `hoehe`.
    @MainActor
    static func imFenster(fensterbreite: CGFloat) -> Bool {
        guard Stil.amPad, fensterbreite > 0 else { return false }
        let schirm = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 0
        return schirm > 0 && fensterbreite < schirm - 8
    }
}
