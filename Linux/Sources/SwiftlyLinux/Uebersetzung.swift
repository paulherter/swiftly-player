import Foundation

/// Kurzer Weg zu einem übersetzten Text aus dem Katalog dieser App.
///
/// **Warum es das hier noch einmal gibt.** ``JellyfinKit`` hat seinen eigenen
/// Katalog und seine eigene Hülle — ein Bündel findet nur, was in ihm liegt.
/// Die Oberfläche dieser App bringt ihre Texte selbst mit, also braucht sie
/// ihren eigenen. Die beiden sehen gleich aus und heissen gleich; das ist
/// Absicht, damit man beim Lesen nicht überlegen muss, welcher gerade gilt.
///
/// **Der deutsche Wortlaut ist zugleich der Schlüssel** — dieselbe
/// Entscheidung wie überall im Projekt. Fehlt der Katalog, kommt nicht
/// `player.error.42` heraus, sondern der richtige deutsche Satz.
///
/// **Serverdaten laufen hier nie durch** (E7). Übersetzt wird ausschliesslich,
/// was als Literal im Quelltext steht; ein Filmtitel, der zufällig „Aus"
/// heisst, würde sonst zu „Off".
func uebersetzt(_ schluessel: String) -> String {
    NSLocalizedString(schluessel, bundle: .module, comment: "")
}
