import CGtk
import Foundation

/// Einstiegspunkt. Alles Weitere steht in ``App``.
///
/// **Die App lebt in einer globalen Referenz**, weil GTKs Rückrufe aus C
/// kommen und nichts einfangen können. Sie wird beim Start einmal erzeugt und
/// hält sich bis zum Ende.
// **Pango soll unter Windows denselben Weg gehen wie unter Linux.**
//
// PangoCairo hat dort zwei Rueckseiten: die von Win32 und die von fontconfig.
// Ohne Angabe nimmt es Win32 — und die kennt weder unsere mitgelieferte
// Schrift noch dieselbe Ausrichtung der Buchstaben wie Linux und der Mac.
// Gemessen: mit der Vorgabe blieb die Oberflaeche auf Segoe UI, obwohl Inter
// danebenlag und ordnungsgemaess angemeldet war.
//
// Muss vor allem anderen stehen: die Schriftenkarte entsteht beim ersten
// Text, und danach ist die Wahl nicht mehr zu aendern. Die 0 heisst
// „nicht ueberschreiben" — wer es selbst setzt, behaelt seine Wahl.
#if os(Windows)
_ = g_setenv("PANGOCAIRO_BACKEND", "fc", 0)
#endif

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
//
// `G_APPLICATION_NON_UNIQUE` kommt nicht als Name in Swift an — die Aufzählung
// heisst in glib seit 2.74 anders, und die alten Namen sind nur noch Makros.
// 32 ist der Wert, den sie seit jeher trägt (das sechste Bit).
#if os(Windows)
let merkmale = GApplicationFlags(rawValue: 32)
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
