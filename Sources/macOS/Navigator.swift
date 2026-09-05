import JellyfinKit
import Observation
import SwiftUI

/// Der Seitenstapel je Bereich — **selbst geführt statt `NavigationStack`.**
///
/// Der Grund ist nicht Geschmack. `NavigationStack` hat auf dem Mac dreimal
/// etwas mitgebracht, das wir wieder abstellen mussten: einen Zurückpfeil in
/// der Fensterampel, einen Werkzeugleisten-Grund über dem Bild, und einen
/// Sicherheitsrand, der mal ankam und mal nicht. Was er dafür liefern sollte —
/// eine Bewegung beim Öffnen und Schließen — liefert er hier gar nicht.
///
/// Ein eigener Stapel ist ein Feld und zwei Methoden. Dafür gilt die Regel aus
/// `Stil` wörtlich: **tiefer gehen schiebt von rechts, zurück schiebt nach
/// rechts hinaus.**
@MainActor
@Observable
final class Navigator {
    /// Was auf welchem Bereich liegt. Wer zwischen Filmen und Serien
    /// wechselt, findet zurück, wo er war.
    private var stapel: [Bereich: [Seitenziel]] = [:]

    func seiten(_ bereich: Bereich) -> [Seitenziel] { stapel[bereich] ?? [] }

    func oeffne(_ ziel: Seitenziel, in bereich: Bereich) {
        // **Ohne Animation anlegen.** Die Seite soll erst dastehen und
        // ausgelegt sein; die Bewegung startet `HauptView` ein Einzelbild
        // später über `gezeigteTiefe`.
        stapel[bereich, default: []].append(ziel)
    }

    func zurueck(in bereich: Bereich) {
        guard !(stapel[bereich] ?? []).isEmpty else { return }
        withAnimation(Stil.zeitSeitenschub) {
            stapel[bereich]?.removeLast()
        }
    }
}

/// Wohin eine Seite führen kann.
///
/// Eigener Typ statt `any Hashable`: der Stapel muss vergleichbar sein, damit
/// SwiftUI den Wechsel als solchen erkennt — und ein Aufzählungstyp sagt beim
/// Lesen, welche Ziele es überhaupt gibt.
enum Seitenziel: Hashable, Identifiable {
    case titel(Item)
    case profil
    case einstellungen
    case wiedergabe
    case quickConnect
    case kontoHinzufuegen

    var id: String {
        switch self {
        case let .titel(item):  "titel-\(item.id)"
        case .profil:           "profil"
        case .einstellungen:    "einstellungen"
        case .wiedergabe:       "wiedergabe"
        case .quickConnect:     "quickconnect"
        case .kontoHinzufuegen: "kontohinzufuegen"
        }
    }

    static func == (a: Seitenziel, b: Seitenziel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Welcher Bereich gerade sichtbar ist.
///
/// Über die Umgebung, weil jede Kachel tief im Baum wissen muss, auf welchen
/// Stapel sie legt — und ein durchgereichter Wert hätte durch jede Ansicht
/// dazwischen gemusst, die ihn selbst gar nicht braucht.
extension EnvironmentValues {
    @Entry var bereich: Bereich = .start
}
