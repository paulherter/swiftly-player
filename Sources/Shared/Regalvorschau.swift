import Foundation

/// Was auf dem Top Shelf steht — die Reihe über dem App-Zeichen auf dem
/// Startbildschirm des Apple TV.
///
/// **Die App schreibt, die Erweiterung liest.** Die Erweiterung läuft in
/// einem eigenen Prozess, hat keinen Zugriff auf den Schlüsselbund der App
/// und soll auch nicht selbst mit dem Server sprechen: sie wird jedes Mal
/// aufgerufen, wenn jemand auf dem Startbildschirm über das Zeichen fährt,
/// und muss sofort etwas zeigen. Also legt die App bei jedem Laden der
/// Startseite eine fertige Liste in den geteilten Ordner, und die Erweiterung
/// zeichnet sie nur noch.
///
/// Die Bildadressen tragen Jellyfins `api_key` bereits in sich — deshalb
/// braucht die Erweiterung keine Anmeldung, um sie zu holen.
struct Regaleintrag: Codable, Sendable, Identifiable {
    let id: String
    let titel: String
    let unterzeile: String?
    let bild: URL?
    /// Anteil zwischen 0 und 1, nur bei Angefangenem.
    let fortschritt: Double?
}

/// Eine Rubrik mit ihren Einträgen — „Weiterschauen", „Nächste Folge",
/// „Zuletzt hinzugefügt".
struct Regalrubrik: Codable, Sendable {
    let titel: String
    /// Waagerechte Standbilder statt hochkanter Plakate. Nur
    /// „Weiterschauen" zeigt Standbilder, wie in der App auch.
    let quer: Bool
    let eintraege: [Regaleintrag]
}

struct Regalvorschau: Codable, Sendable {
    let rubriken: [Regalrubrik]
}

/// Der geteilte Ablageort.
enum Regal {
    /// Muss in den Berechtigungen **beider** Ziele stehen, sonst ist der
    /// Ordner für eines von beiden nicht da und alles bleibt still.
    static let gruppe = "group.de.paulherter.swiftly"

    private static var datei: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: gruppe)?
            .appendingPathComponent("regal.json")
    }

    static func schreiben(_ vorschau: Regalvorschau) {
        guard let datei, let daten = try? JSONEncoder().encode(vorschau) else { return }
        try? daten.write(to: datei, options: .atomic)
    }

    /// **Beim Abmelden zu leeren ist Pflicht, nicht Kosmetik.**
    ///
    /// Die Datei liegt in der geteilten Gruppe und ueberlebt das Abmelden.
    /// Ohne dieses Leeren stehen im Top Shelf weiter die Filme und Serien des
    /// vorigen Kontos — sichtbar auf dem Startbildschirm des Fernsehers, fuer
    /// jeden im Raum, auch nachdem sich jemand ausdruecklich abgemeldet hat.
    static func leeren() {
        guard let datei else { return }
        try? FileManager.default.removeItem(at: datei)
    }

    static func lesen() -> Regalvorschau? {
        guard let datei, let daten = try? Data(contentsOf: datei) else { return nil }
        return try? JSONDecoder().decode(Regalvorschau.self, from: daten)
    }
}
