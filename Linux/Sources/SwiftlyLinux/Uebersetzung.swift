import Foundation
import JellyfinKit

/// Der Katalog dieser Oberfläche, einmal beim Start gelesen.
///
/// **Warum nicht `NSLocalizedString`.** Am 05.09.2026 an der ausgelieferten
/// 1.0.0 gemessen: der Aufruf nimmt auf Linux die **Entwicklungssprache** des
/// Bündels — hier `defaultLocalization: "de"` —, obwohl das Bündel `en` als
/// bevorzugte Sprache meldet. Linux hat keine Apple-Spracheinstellung, aus der
/// CFBundle wählen könnte, also stand die Oberfläche bei jedem Nutzer auf
/// Deutsch, egal welche Sprache sein System hatte. Die Kataloge waren dabei in
/// Ordnung; nur der Nachschlagweg war es nicht.
///
/// ``Textkatalog`` macht ihn selbst: Sprache aus der Umgebung, Datei über
/// `url(…, localization:)`, gelesen mit `NSDictionary(contentsOf:)` — der
/// Weg, der nachweislich trägt. Er liegt im Paket, weil beide Ziele ihn
/// brauchen; geteilt ist das Verfahren, nicht der Inhalt.
let oberflaechenkatalog = Textkatalog(bundle: .module)

/// Kurzer Weg zu einem übersetzten Text aus dem Katalog dieser App.
///
/// **Warum es das hier noch einmal gibt.** ``JellyfinKit`` hat seinen eigenen
/// Katalog und seine eigene Hülle — ein Bündel findet nur, was in ihm liegt.
/// Die Oberfläche dieser App bringt ihre Texte selbst mit, also braucht sie
/// ihren eigenen. Die beiden sehen gleich aus und heissen gleich; das ist
/// Absicht, damit man beim Lesen nicht überlegen muss, welcher gerade gilt.
///
/// **Der Schlüssel bleibt hier ein schlichter `String`** — anders als im
/// Paket, wo ``Textschluessel`` die Interpolation abfängt. Die Oberfläche
/// setzt ihre Platzhalter selbst ein (`String(format: uebersetzt("%@ als
/// gesehen"), name)`), der Platzhalter steht also schon im Literal und darf
/// hier nicht angerührt werden.
///
/// **Der deutsche Wortlaut ist zugleich der Schlüssel** — dieselbe
/// Entscheidung wie überall im Projekt. Fehlt der Katalog, kommt nicht
/// `player.error.42` heraus, sondern der richtige deutsche Satz.
///
/// **Serverdaten laufen hier nie durch** (E7). Übersetzt wird ausschliesslich,
/// was als Literal im Quelltext steht; ein Filmtitel, der zufällig „Aus"
/// heisst, würde sonst zu „Off".
func uebersetzt(_ schluessel: String) -> String {
    oberflaechenkatalog.text(Textschluessel(schluessel))
}
