import CGtk
import Foundation

/// **Eine Datei sagt der App, wohin sie gehen soll.**
///
/// Das Gegenstück zu `Fensterabzug` auf dem Mac (`touch abzug.jetzt`), nur
/// andersherum: Bilder macht auf Linux `spectacle`, was fehlt, ist der Weg
/// *zur* Seite.
///
/// **Warum es das braucht.** Eine Sitzung soll nachsehen, bevor sie etwas
/// meldet — so steht es im Übernahmeskill, und der Blick kostet dreißig
/// Sekunden gegen eine ganze Runde über Paul. Auf Linux ging das nicht:
/// `ydotool` erreicht die App auf dieser Wayland-Sitzung nicht, egal mit
/// welchen Koordinaten. Am 13.09.2026 sind dadurch zwei Behebungen
/// ausgeliefert worden, die gar nicht griffen, und drei Seiten galten als
/// angepasst, die es nicht waren. Blind bauen ist teurer als das hier.
///
/// **Nur im Debug-Bau.** Im Auslieferungsbau gibt es die Datei nicht und den
/// Takt auch nicht — eine App, die auf Zuruf durch ihre Seiten springt, ist
/// eine Fernsteuerung, die niemand bestellt hat.
///
/// ```bash
/// echo profil > /tmp/swiftly-zeige      # Profil
/// echo serie:<id> > /tmp/swiftly-zeige  # eine Serienseite
/// echo reiter:besetzung > /tmp/swiftly-zeige
/// ```
/// Der Takt selbst — als freie Funktion, weil ein C-Zeiger keine Closure mit
/// Umgebung annimmt.
private nonisolated(unsafe) let pultTakten: @convention(c) (gpointer?) -> gboolean = { daten in
    guard let daten else { return 0 }
    let app = Unmanaged<App>.fromOpaque(daten).takeUnretainedValue()
    guard let wort = try? String(contentsOf: Fernsteuerpult.anstoss, encoding: .utf8)
    else { return 1 }
    try? FileManager.default.removeItem(at: Fernsteuerpult.anstoss)
    app.fernbefehl(wort.trimmingCharacters(in: .whitespacesAndNewlines))
    return 1
}

enum Fernsteuerpult {

    static let anstoss = URL(fileURLWithPath: "/tmp/swiftly-zeige")

    /// Anderthalb Sekunden Takt — dieselbe Zahl wie auf dem Mac, aus
    /// demselben Grund: langsam genug, um im Betrieb nicht aufzufallen,
    /// schnell genug, um nicht darauf zu warten.
    static func lauschen(_ app: App) {
        #if DEBUG
        _ = g_timeout_add_seconds(2, pultTakten, Unmanaged.passUnretained(app).toOpaque())
        #endif
    }
}

extension App {

    /// Führt einen Befehl aus dem ``Fernsteuerpult`` aus.
    func fernbefehl(_ wort: String) {
        let teile = wort.split(separator: ":", maxSplits: 1).map(String.init)
        switch teile.first {
        case "start":       zeige(.start)
        case "filme":       zeige(.filme)
        case "serien":      zeige(.serien)
        case "suche":       zeige(.suche)
        case "merkliste":   zeige(.merkliste)
        case "downloads":   zeige(.downloads)
        case "profil":      unterseiteOeffnen(.profil)
        case "einstellungen": unterseiteOeffnen(.einstellungen)
        case "wiedergabe":  unterseiteOeffnen(.wiedergabe)
        case "darstellung": unterseiteOeffnen(.darstellung)
        case "quickconnect": unterseiteOeffnen(.quickConnect)
        case "zurueck":     zurueck()

        /// Den ersten Titel einer Reihe öffnen — ohne seine Kennung zu kennen.
        case "ersterTitel":
            if let erster = rasterItems[bereich]?.first ?? letzteStartreihe.first {
                oeffne(erster)
            }

        /// Einen Reiter der Serienseite wählen.
        case "reiter":
            switch teile.count > 1 ? teile[1] : "" {
            case "folgen":     reiterWaehlen?(.folgen)
            case "besetzung":  reiterWaehlen?(.besetzung)
            case "aehnliches": reiterWaehlen?(.aehnliches)
            default: break
            }

        /// Die erste Person der Besetzung öffnen.
        case "erstePerson":
            if let titel = seitenstapel[bereich]?.last,
               let erste = titel.darsteller.first {
                oeffnePerson(erste, herkunft: titel.name)
            }
        default: break
        }
    }
}
