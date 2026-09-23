import CGtk
import Foundation
#if os(Windows)
import WinSDK
#endif

/// **Waehrend der Wiedergabe geht der Bildschirm nicht aus.**
///
/// Bis zum 23.09.2026 hemmten Linux und Windows den Bildschirmschoner gar
/// nicht: nach der eingestellten Leerlaufzeit wurde mitten im Film dunkel.
/// Gehemmt wird, solange libVLC laeuft; bei Pause und beim Schliessen des
/// Players wird freigegeben, wie auf den Apple-Fassungen
/// (`isIdleTimerDisabled` bzw. die Energiesperre des Mac).
///
/// Linux ueber `gtk_application_inhibit` (Leerlauf), Windows ueber
/// `SetThreadExecutionState` — das gilt je Faden, deshalb nur vom
/// Hauptfaden rufen; das Laufzustands-Ereignis kommt dort schon an.
enum Wachhalter {
    #if os(Windows)
    nonisolated(unsafe) private static var aktiv = false
    #else
    nonisolated(unsafe) private static var marke: guint = 0
    /// Bei wem gehemmt wurde — freigegeben wird bei derselben Anwendung,
    /// auch wenn das Ende aus VLCs Ereignis kommt und kein Fenster kennt.
    nonisolated(unsafe) private static var anwendung: UnsafeMutablePointer<GtkApplication>?
    #endif

    /// Gestoppt, zu Ende oder mit Fehler abgebrochen — dann kommt kein
    /// `Paused` mehr, und ohne das bliebe die Hemmung bis zum Schliessen.
    static func freigeben() { setzen(false, fenster: nil) }

    static func setzen(_ wach: Bool, fenster: Widget!) {
        #if os(Windows)
        guard wach != aktiv else { return }
        aktiv = wach
        // ES_CONTINUOUS 0x80000000, ES_DISPLAY_REQUIRED 0x2,
        // ES_SYSTEM_REQUIRED 0x1 — als Zahlen, weil die Makros mit ihrer
        // Umwandlung `((DWORD)…)` nicht verlaesslich nach Swift kommen.
        let merkmale: EXECUTION_STATE = wach ? 0x8000_0003 : 0x8000_0000
        _ = SetThreadExecutionState(merkmale)
        Protokoll.schreib("[Wach] \(wach ? "gehemmt" : "freigegeben")")
        #else
        if wach {
            guard marke == 0, let fenster,
                  let neu = gtk_window_get_application(alsFenster(fenster)) else { return }
            marke = gtk_application_inhibit(neu, alsFenster(fenster),
                                            GTK_APPLICATION_INHIBIT_IDLE, "Wiedergabe")
            anwendung = neu
            Protokoll.schreib("[Wach] gehemmt (\(marke))")
        } else {
            guard marke != 0, let anwendung else { return }
            gtk_application_uninhibit(anwendung, marke)
            Protokoll.schreib("[Wach] freigegeben (\(marke))")
            marke = 0
        }
        #endif
    }
}
