import Foundation

// **Eigene Datei, damit der Fernseher sie auch bekommt.**
//
// Sie stand in `Bausteine.swift`, und die bindet das tvOS-Ziel nicht ein —
// also gab es auf dem Apple TV keine Fassungsangabe. Aufgefallen am
// 05.09.2026, als ein Tester nach seiner Baunummer gefragt wurde und sie
// nirgends stand. Genau die Angabe, die ein Fehlerbericht braucht.

/// Was unten auf der Profilseite steht: „Swiftly for Jellyfin 1.0.1 (Build 12)".
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
    static var zeile: String {
        let b = Bundle.main.infoDictionary
        let fassung = b?["CFBundleShortVersionString"] as? String ?? "?"
        let bau = b?["CFBundleVersion"] as? String ?? "?"
        return "Swiftly for Jellyfin \(fassung) (Build \(bau))"
    }
}
