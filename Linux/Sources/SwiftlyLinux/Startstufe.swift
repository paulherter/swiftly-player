import Foundation

/// **Wie weit der Start gekommen ist — eine Zeile je Stufe im Protokoll.**
///
/// Unter Windows liest das Startprogramm (`Windows/Startprogramm`) diese
/// Zeilen mit: es leitet stdout der App nach `%APPDATA%\Swiftly\swiftly.log`
/// und zeigt im Ladefenster die jeweils letzte Stufe. Der Name nach
/// `[Stufe]` ist deshalb eine Schnittstelle — wer einen umbenennt, benennt
/// ihn dort in der Tabelle `stufen` mit um. Eine unbekannte Stufe zeigt das
/// Startprogramm roh; kaputt geht nichts.
///
/// Unter Linux landet die Zeile nur im bestehenden Protokoll, das das
/// Startskript schreibt. Kein Fenster, kein zweiter Weg.
///
/// **Nie etwas Geheimes als Stufe.** Keine Adresse, kein Name, kein Token —
/// die Datei schickt ein Nutzer im Zweifel weiter.
enum Startstufe {
    static func melden(_ name: String) {
        let u = DateFormatter()
        u.dateFormat = "HH:mm:ss.SSS"
        print("\(u.string(from: Date())) [Stufe] \(name)")
        // Sofort hinaus: in eine Datei ist `print` blockweise gepuffert, und
        // das Startprogramm soll die Stufe sehen, wenn sie erreicht ist —
        // nicht, wenn der Puffer voll ist. Siehe `Spur.schreiben` in main.swift.
        fflush(nil)
    }
}
