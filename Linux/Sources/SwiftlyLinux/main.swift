import CGtk
import Foundation

/// Einstiegspunkt. Alles Weitere steht in ``App``.
///
/// **Die App lebt in einer globalen Referenz**, weil GTKs Rückrufe aus C
/// kommen und nichts einfangen können. Sie wird beim Start einmal erzeugt und
/// hält sich bis zum Ende.
nonisolated(unsafe) let app = App()

nonisolated(unsafe) private let starten: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { anwendung, _ in
    Stil.anwenden()
    app.aufbauen(anwendung: anwendung!.assumingMemoryBound(to: GtkApplication.self))
    app.kopfzeileEinrichten()
}

// **Ohne Sitzungsbus gibt es keine Einmaligkeit.**
//
// `GApplication` meldet sich beim Start auf D-Bus an — daher kommt das
// Verhalten, dass eine zweite Kopie die erste nach vorn holt statt ein zweites
// Fenster zu öffnen. Unter Windows gibt es diesen Bus nicht: die Anmeldung
// schlägt fehl, und `g_application_run` kehrt zurück, **ohne das Fenster je zu
// bauen**. Gemessen beim ersten Start: die App war nach einer Zehntelsekunde
// wieder weg, mit nichts als einer Warnung über den fehlenden Bus.
//
// Der Preis ist, dass sich die App unter Windows zweimal starten lässt. Das
// ist dort auch das übliche Verhalten.
#if os(Windows)
let merkmale = G_APPLICATION_NON_UNIQUE
#else
let merkmale = GApplicationFlags(rawValue: 0)
#endif

let anwendung = gtk_application_new("de.paulherter.swiftly", merkmale)
g_signal_connect_data(UnsafeMutableRawPointer(anwendung), "activate",
                      unsafeBitCast(starten, to: GCallback.self),
                      nil, nil, GConnectFlags(rawValue: 0))

let ergebnis = g_application_run(
    unsafeBitCast(anwendung, to: UnsafeMutablePointer<GApplication>.self), 0, nil)
exit(ergebnis)
