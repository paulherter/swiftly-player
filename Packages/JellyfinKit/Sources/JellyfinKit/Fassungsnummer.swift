import Foundation

/// Die Fassung, mit der sich die App beim Server meldet.
///
/// **Hier stand „0.1.0" als Vorgabewert im `JellyfinClient`, und niemand hat
/// je etwas anderes uebergeben.** Am 10.09.2026 in Jellyfins eigener
/// Sitzungsuebersicht gesehen: „iPhone · Swiftly 0.1.0" — bei einer App, die
/// als 1.0.1 im Store liegt. Eine Fassungsnummer, die nie gestimmt hat, ist
/// schlimmer als keine: sie steht in jedem Fehlerbericht, den ein Nutzer aus
/// dieser Uebersicht abschreibt.
///
/// Dieselbe Lehre wie bei ``Fassung`` in der App: **aus dem Buendel gelesen,
/// nicht getippt.** Eine Zahl, die von Hand gepflegt werden muss, laeuft
/// auseinander, und man merkt es an der Stelle nicht.
public enum Fassungsnummer {

    /// `CFBundleShortVersionString`, oder „unbekannt", wenn es kein Buendel
    /// gibt — auf Linux und Windows laeuft dieselbe Paketfassung, und dort
    /// gibt es keine Info-Liste. Die Fassungen dort setzen den Wert selbst.
    public static let ausDemBuendel: String = {
        let b = Bundle.main.infoDictionary
        if let kurz = b?["CFBundleShortVersionString"] as? String, !kurz.isEmpty {
            if let bau = b?["CFBundleVersion"] as? String, !bau.isEmpty {
                return "\(kurz) (\(bau))"
            }
            return kurz
        }
        return "unbekannt"
    }()
}
