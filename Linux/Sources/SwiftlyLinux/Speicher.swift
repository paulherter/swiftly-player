import Foundation
import JellyfinKit

/// Wo die Anmeldung zwischen zwei Starts liegt.
///
/// **Auf Apple ist das der Schlüsselbund, hier ist es eine Datei.** Linux hat
/// keinen systemweiten Schlüsselbund, auf den man sich verlassen kann — je
/// nach Desktop ist es GNOME Keyring, KWallet oder gar nichts, und alle drei
/// sprechen verschiedene Sprachen. Eine Datei mit `0600` in `~/.config` ist
/// dafür der ehrliche Ersatz: nur der eigene Benutzer kommt heran, und es ist
/// dieselbe Stelle, an der auch alle anderen Programme ihre Zugänge ablegen.
///
/// **Was hier liegt, ist ein Zugangstoken, kein Passwort.** Das Passwort geht
/// einmal an den Server und wird nie gespeichert; zurück kommt ein Token, das
/// sich am Server widerrufen lässt. Der Unterschied ist wichtig genug, um ihn
/// aufzuschreiben.
enum Speicher {

    struct Abgelegt: Codable {
        let serverURL: URL
        let token: String
        let benutzerID: String
        let benutzername: String
        let servername: String?
    }

    private static var ordner: URL { Plattform.einstellungsordner }

    /// **Nur der Besitzer darf hinein.** Die Datei traegt den Anmeldeschluessel
    /// des Servers; auf einem Rechner mit mehreren Konten hat sonst jeder
    /// Zugriff darauf.
    ///
    /// Unter Windows gibt es keine Unix-Rechte. Der Ordner liegt dort unter
    /// `%APPDATA%` und ist ueber die Zugriffsliste des Systems ohnehin nur fuer
    /// den Besitzer lesbar — die Angabe waere dort nicht bloss wirkungslos,
    /// sondern wuerde beim Anlegen einen Fehler werfen.
    private static var nurIch: [FileAttributeKey: Any] {
        #if os(Windows)
        return [:]
        #else
        return [.posixPermissions: 0o700]
        #endif
    }

    private static var datei: URL { ordner.appendingPathComponent("sitzung.json") }

    static func lesen() -> Abgelegt? {
        guard let daten = try? Data(contentsOf: datei) else { return nil }
        return try? JSONDecoder().decode(Abgelegt.self, from: daten)
    }

    static func schreiben(_ eintrag: Abgelegt) {
        do {
            try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true,
                                                    attributes: nurIch)
            let daten = try JSONEncoder().encode(eintrag)
            try daten.write(to: datei, options: [.atomic])
            // **Erst nach dem Schreiben.** `write(options:.atomic)` legt eine
            // neue Datei an und benennt sie um; Rechte, die vorher gesetzt
            // wurden, wären danach wieder die alten.
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: datei.path)
            #endif
        } catch {
            FileHandle.standardError.write(
                Data("Sitzung ließ sich nicht sichern: \(error.localizedDescription)\n".utf8))
        }
    }

    static func loeschen() {
        try? FileManager.default.removeItem(at: datei)
    }

    // MARK: Zuletzt verbunden

    /// **Der zuletzt benutzte Server, auch nach dem Abmelden.**
    ///
    /// Abmelden loeschte bisher alles — beim naechsten Start stand wieder ein
    /// leeres Adressfeld, und man tippte `tv.paulherter.de` von Hand. Der Mac
    /// merkt sich Adresse, Name und Fassung getrennt von der Sitzung
    /// (`Shared/Anmeldemodell.swift:15`); die Zugangsdaten sind damit weg, der
    /// Weg dorthin nicht.
    struct Merkzettel: Codable {
        let serverURL: URL
        let servername: String?
        let fassung: String?
    }

    private static var merkdatei: URL { ordner.appendingPathComponent("server.json") }

    static func serverMerken(_ eintrag: Merkzettel) {
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true,
                                                 attributes: nurIch)
        guard let daten = try? JSONEncoder().encode(eintrag) else { return }
        try? daten.write(to: merkdatei, options: [.atomic])
    }

    static func gemerkterServer() -> Merkzettel? {
        guard let daten = try? Data(contentsOf: merkdatei) else { return nil }
        return try? JSONDecoder().decode(Merkzettel.self, from: daten)
    }
}
