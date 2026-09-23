import Foundation
import JellyfinKit
// Auf Linux und Windows liegt der Netzteil von Foundation in einem eigenen
// Modul; auf Apple ist er in Foundation enthalten. Dieselbe Zeile steht aus
// demselben Grund in `JellyfinClient`.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Nach einer neueren Fassung sehen und sie einspielen — nur unter Windows.**
///
/// Auf Linux macht das die Paketquelle: wer über `swiftly-installieren.sh`
/// eingerichtet hat, bekommt Swiftly mit den übrigen Systemaktualisierungen.
/// Unter Windows gibt es nichts dergleichen; dort lädt ein Zuschauer den
/// Installer von Hand von der Veröffentlichungsseite, und das merkt er sich
/// nicht.
///
/// **Nur auf Druck, nie von selbst.** Die App fragt beim Start nicht nach.
/// Das ist eine Entscheidung und keine Bequemlichkeit: GitHub zählt anonyme
/// Anfragen je Adresse (sechzig in der Stunde), und eine App, die bei jedem
/// Start nachsieht, wird zum Selbstläufer, ohne dass jemand darum gebeten
/// hätte. Eingespielt wird ebenfalls erst auf Druck.
enum Aktualisierung {

    /// Woher die Auskunft kommt. Ohne Zugangsschlüssel, also ohne alles, was
    /// aus einem Protokoll herausgeschnitten werden müsste.
    private static let auskunft =
        URL(string: "https://api.github.com/repos/paulherter/swiftly-player/releases/latest")!

    struct Stand {
        /// „1.0.4" — ohne das `v` des Kennzeichens.
        let fassung: String
        /// Die Baunummer aus dem Text der Veröffentlichung, falls sie eine nennt.
        let bau: Int?
        let adresse: URL
        /// Was sich ändert, wie es auf der Veröffentlichungsseite steht.
        let notizen: String
        let groesse: Int
    }

    enum Fehler: Error {
        case keineAntwort
        case keinInstallierer
    }

    // MARK: Suchen

    /// `nil` heißt: es gibt nichts Neueres.
    static func suchen() async throws -> Stand? {
        var anfrage = URLRequest(url: auskunft)
        // GitHub verlangt eine Kennung und liefert sonst 403.
        anfrage.setValue("Swiftly/\(Fassung.nummer)", forHTTPHeaderField: "User-Agent")
        anfrage.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        anfrage.timeoutInterval = 20
        let (daten, antwort) = try await URLSession.shared.data(for: anfrage)
        guard let http = antwort as? HTTPURLResponse, http.statusCode == 200,
              let roh = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
        else { throw Fehler.keineAntwort }

        let kennzeichen = (roh["tag_name"] as? String) ?? ""
        let fassung = kennzeichen.hasPrefix("v") ? String(kennzeichen.dropFirst()) : kennzeichen
        let notizen = (roh["body"] as? String) ?? ""
        let bau = baunummer(aus: notizen)

        guard neuerAlsUnsere(fassung: fassung, bau: bau) else { return nil }

        // **Der Windows-Installer, nicht das erstbeste Anhängsel.** An einer
        // Veröffentlichung hängen auch `.deb`, `.rpm` und ein Tarball.
        let anhaenge = (roh["assets"] as? [[String: Any]]) ?? []
        guard let exe = anhaenge.first(where: {
            (($0["name"] as? String) ?? "").lowercased().hasSuffix("-setup.exe")
        }), let ort = exe["browser_download_url"] as? String, let adresse = URL(string: ort)
        else { throw Fehler.keinInstallierer }

        return Stand(fassung: fassung, bau: bau, adresse: adresse, notizen: notizen,
                     groesse: (exe["size"] as? Int) ?? 0)
    }

    /// Beides liegt im Paket (``JellyfinKit/Fassungsvergleich``), weil die
    /// GTK-Schicht kein Testziel hat. Dort stehen neun Tests dazu — unter
    /// anderem der, dass 1.0.10 neuer ist als 1.0.9.
    static func baunummer(aus text: String) -> Int? {
        Fassungsvergleich.baunummer(ausText: text)
    }

    static func neuerAlsUnsere(fassung: String, bau: Int?) -> Bool {
        Fassungsvergleich.neuer(dort: fassung, hier: Fassung.nummer,
                                bauDort: bau, bauHier: Int(Fassung.bau) ?? 0)
    }

    // MARK: Holen und starten

    /// **Die Datei wird selbst geschrieben, und das ist der Punkt.**
    ///
    /// Windows heftet an alles, was über `URLDownloadToFile` oder den
    /// Anhangdienst hereinkommt, einen zweiten Datenstrom namens
    /// `Zone.Identifier` — die Herkunftsmarke. An ihr hängt SmartScreen: eine
    /// markierte, unsignierte Datei wird beim Start beanstandet. Was ein
    /// Programm selbst mit gewöhnlichem Schreiben anlegt, bekommt sie nicht.
    ///
    /// Deshalb hier `URLSession` und ein eigenes `write`, und deshalb steht
    /// es als Satz da: wer das später durch etwas Bequemeres ersetzt, holt
    /// sich die Warnung zurück, und niemand würde den Zusammenhang sehen.
    static func holen(_ stand: Stand) async throws -> URL {
        var anfrage = URLRequest(url: stand.adresse)
        anfrage.setValue("Swiftly/\(Fassung.nummer)", forHTTPHeaderField: "User-Agent")
        anfrage.timeoutInterval = 600
        let (daten, _) = try await URLSession.shared.data(for: anfrage)
        let ziel = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Swiftly-\(stand.fassung)-Setup.exe")
        try? FileManager.default.removeItem(at: ziel)
        try daten.write(to: ziel)
        return ziel
    }

    /// Den Installer starten und die App beenden — er kann eine laufende
    /// `Swiftly.exe` nicht ersetzen.
    static func einspielen(_ datei: URL) throws {
        let lauf = Process()
        lauf.executableURL = datei
        try lauf.run()
    }
}
