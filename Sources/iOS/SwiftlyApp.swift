import SwiftUI

@main
struct SwiftlyApp: App {
    @UIApplicationDelegateAdaptor(SwiftlyAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { RootView() }
            // **Ohne das bleibt ein Download im Hintergrund liegen.**
            //
            // Eine 18-GB-Datei laedt nicht in den dreissig Sekunden, die iOS
            // einer App im Hintergrund laesst; die Hintergrundsitzung gibt
            // den Vorgang deshalb an einen Systemdienst ab, der weiterlaeuft,
            // wenn die App beendet ist. Wird sie fertig, **startet iOS die
            // App eigens dafuer wieder** — und erwartet, dass jemand
            // hinsieht. Fehlt diese Zeile, kommt der Start ins Leere: die
            // fertige Datei bleibt in Apples Zwischenablage stehen, und beim
            // naechsten Oeffnen faengt der Download von vorn an.
            //
            // Die Kennung muss dieselbe sein wie in `Downloadverwaltung` —
            // daher von dort, nicht getippt.
            .backgroundTask(.urlSession(Downloadverwaltung.sitzungskennung)) {
                // Das blosse Aufwachen genuegt: die Sitzung stellt ihre
                // Rueckrufe von selbst zu, sobald das Modell sie anfasst.
                // Hier steht nichts zu tun — aber die Zeile muss stehen.
            }
    }
}
