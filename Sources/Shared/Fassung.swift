import Foundation

// **Eigene Datei, damit der Fernseher sie auch bekommt.**
//
// Sie stand in `Bausteine.swift`, und die bindet das tvOS-Ziel nicht ein —
// also gab es auf dem Apple TV keine Fassungsangabe. Aufgefallen am
// 05.09.2026, als ein Tester nach seiner Baunummer gefragt wurde und sie
// nirgends stand. Genau die Angabe, die ein Fehlerbericht braucht.

/// Was unten auf der Profilseite steht: „Swiftly Player 1.0.1 (Build 1)".
///
/// **Aus dem Bündel gelesen, nicht getippt.** Auf dem iPhone stand hier
/// einmal „Swiftly 1.0" — eine Zahl, die niemand mitgezogen hat und die seit
/// der ersten Abgabe falsch war. Eine Fassungsangabe, die man von Hand
/// pflegen muss, ist schlimmer als keine: sie sieht verlässlich aus.
///
/// Die Baunummer gehört dazu, weil sie in einem Fehlerbericht die eigentliche
/// Auskunft ist — „1.0.0" haben zwoelf Builds getragen.
///
/// **Warum hier und nicht in `ProfilView`.** Sie stand als `static` in
/// `Sources/Shared/ProfilView.swift`, und die Datei gehört dem iPhone; der
/// Mac hat seine eigene Profilseite und kam nicht heran. Genau so entstehen
/// die Kopien, die dieser Datei ihren Namen gegeben haben — deshalb steht die
/// Rechnung dort, wo alle sie sehen, und die Ansichten setzen nur den Text.
enum Fassung {

    /// Die Fassung des Abspielers. **Einmal, nicht dreimal getippt** — sie
    /// stand wörtlich in `Sources/Shared/EinstellungenView.swift` und noch
    /// einmal in `Sources/macOS/EinstellungenView.swift`. Beim nächsten
    /// VLCKit-Wechsel hätte einer davon überlebt.
    static let abspieler = "VLCKit 4.0.0-a23"

    /// Wer die App ist. **Auf der Profilseite**, wo jemand nachsieht, welche
    /// Fassung er hat.
    static var zeile: String {
        let b = Bundle.main.infoDictionary
        let fassung = b?["CFBundleShortVersionString"] as? String ?? "?"
        let bau = b?["CFBundleVersion"] as? String ?? "?"
        // **„Swiftly Player", nicht „Swiftly for Jellyfin".**
        //
        // Apple hat die Einreichung am 07.09.2026 nach Richtlinie 4.1(c)
        // abgelehnt: der Name einer App darf die Produktmarke eines anderen
        // Entwicklers nicht tragen. Der Store-Eintrag heisst deshalb jetzt
        // „Swiftly Player", und diese Zeile steht im Profil derselben App —
        // sie muss dasselbe sagen.
        return "Swiftly Player \(fassung) (Build \(bau))"
    }

    /// Dieselbe Zeile plus den Unterbau. **In den Einstellungen**, weil dort
    /// der Fehlerbericht entsteht.
    ///
    /// Die beiden waren uneinheitlich, und Sie sind es weiter — aber jetzt aus
    /// einem Grund und aus **einer** Quelle: das Profil sagt, wer die App ist,
    /// die Einstellungen sagen, woraus sie besteht. Wer einen Fehler meldet,
    /// wird zu den Einstellungen geschickt, nicht ins Profil.
    static var mitUnterbau: String { zeile + " · " + abspieler }
}
