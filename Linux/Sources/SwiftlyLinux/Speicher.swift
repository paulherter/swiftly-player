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

    private static var ordner: URL {
        let basis = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return basis.appendingPathComponent("swiftly")
    }

    private static var datei: URL { ordner.appendingPathComponent("sitzung.json") }

    static func lesen() -> Abgelegt? {
        guard let daten = try? Data(contentsOf: datei) else { return nil }
        return try? JSONDecoder().decode(Abgelegt.self, from: daten)
    }

    static func schreiben(_ eintrag: Abgelegt) {
        do {
            try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let daten = try JSONEncoder().encode(eintrag)
            try daten.write(to: datei, options: [.atomic])
            // **Erst nach dem Schreiben.** `write(options:.atomic)` legt eine
            // neue Datei an und benennt sie um; Rechte, die vorher gesetzt
            // wurden, wären danach wieder die alten.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: datei.path)
        } catch {
            FileHandle.standardError.write(
                Data("Sitzung ließ sich nicht sichern: \(error.localizedDescription)\n".utf8))
        }
    }

    static func loeschen() {
        try? FileManager.default.removeItem(at: datei)
    }
}
