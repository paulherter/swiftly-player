import Foundation

/// **Bewerten, Discord, Fehler melden — die Adressen und wann die App von
/// selbst darauf hinweist.**
///
/// Die Adressen stehen hier und nirgends sonst: eine Einladung, die in sechs
/// Oberflächen getippt ist, läuft irgendwann an einer davon ab.
///
/// Die App hat kein Konto und zählt nichts nach außen. Gezählt wird nur auf
/// dem Gerät, wie viele Titel zu Ende geschaut wurden (``Bewertungsfrage``).
public enum Gemeinschaft {

    /// Die Einladung, dieselbe wie auf der Website.
    public static let discord = URL(string: "https://discord.gg/MeGwfv3UwN")!

    /// Zum Abtippen, wo es keinen Browser gibt (Fernseher).
    public static let discordKurz = "discord.gg/MeGwfv3UwN"

    /// Öffnet im App Store direkt das Feld zum Bewerten.
    public static let appStoreBewertung = URL(string: "https://apps.apple.com/app/id6806824067?action=write-review")!

    /// Der Eintrag im Play Store — dort liegt das Bewerten einen Tipp tiefer.
    public static let playStore = URL(string: "https://play.google.com/store/apps/details?id=de.paulherter.swiftly")!

    public static let fehlerKurz = "github.com/paulherter/swiftly-player/issues"

    /// Ein neues Issue auf GitHub, mit Fassung und Plattform schon im Text.
    ///
    /// Nur diese zwei Angaben: kein Servername, keine Adresse, nichts, was
    /// jemand nicht selbst in ein öffentliches Issue schreiben würde.
    public static func fehlerMelden(fassung: String, plattform: String) -> URL {
        var teile = URLComponents(string: "https://github.com/paulherter/swiftly-player/issues/new")!
        teile.queryItems = [URLQueryItem(name: "body",
                                         value: "\n\n---\nSwiftly \(fassung) · \(plattform)")]
        return teile.url!
    }

    /// Ab so vielen zu Ende geschauten Titeln kommt der Hinweis auf den
    /// Discord — nach der Bewertungsfrage (3), nicht mit ihr zusammen.
    public static let discordSchwelle = 5

    public enum Anstoss: String, Sendable {
        case bewertung
        case discord
    }

    /// Was nach einem zu Ende geschauten Titel dran ist — höchstens eins.
    ///
    /// Die Bewertungsfrage geht vor. Sind beide fällig (etwa nach einem
    /// Update, wenn schon zehn Titel gezählt sind), kommt der Discord beim
    /// nächsten Titel: zwei Fragen hintereinander wären genau das Nerven, das
    /// dieser Typ verhindern soll.
    ///
    /// - Parameters:
    ///   - fertig: Zu Ende geschaute Titel, **dieser eingerechnet**.
    ///   - bewertungZuletzt: Fassung, in der zuletzt nach einer Bewertung gefragt wurde.
    ///   - fassung: Die laufende Fassung.
    ///   - discordGezeigt: Ob der Hinweis auf dieser Installation schon kam.
    ///   - bewertungMoeglich: Ob die Plattform eine Bewertungsabfrage hat.
    ///     Apple TV und Linux haben keine — dort darf die nie gestellte Frage
    ///     den Discord nicht ewig blockieren.
    public static func anstoss(fertig: Int, bewertungZuletzt: String?, fassung: String,
                               discordGezeigt: Bool, bewertungMoeglich: Bool) -> Anstoss? {
        if bewertungMoeglich,
           Bewertungsfrage.faellig(fertig: fertig, zuletztGefragt: bewertungZuletzt, fassung: fassung) {
            return .bewertung
        }
        if fertig >= discordSchwelle, !discordGezeigt { return .discord }
        return nil
    }
}
