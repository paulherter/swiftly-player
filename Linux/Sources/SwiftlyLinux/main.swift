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

let anwendung = gtk_application_new("de.paulherter.swiftly", GApplicationFlags(rawValue: 0))
g_signal_connect_data(UnsafeMutableRawPointer(anwendung), "activate",
                      unsafeBitCast(starten, to: GCallback.self),
                      nil, nil, GConnectFlags(rawValue: 0))

let ergebnis = g_application_run(
    unsafeBitCast(anwendung, to: UnsafeMutablePointer<GApplication>.self), 0, nil)
exit(ergebnis)
