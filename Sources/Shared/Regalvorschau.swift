import Foundation
#if os(tvOS)
import TVServices
#endif

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
        guard var datei, let daten = try? JSONEncoder().encode(vorschau) else { return }
        // Nur bei echter Aenderung weitermachen: die Bescheidgabe unten laesst
        // tvOS die Erweiterung neu befragen, und das muss nicht bei jedem
        // Oeffnen der Startseite sein.
        let vorher = try? Data(contentsOf: datei)
        guard vorher != daten else { return }
        try? daten.write(to: datei, options: .atomic)
        // **Nicht in die Sicherung.**
        //
        // Die Bildadressen hier drin tragen Jellyfins `api_key` — das steht
        // oben ausdruecklich so da, weil die Erweiterung ohne ihn nicht an
        // die Bilder kaeme. Damit liegt in dieser Datei ein vollwertiger
        // Serverzugang ohne Ablauf, und zwar unverschluesselt: der
        // Schluesselbund haelt ihn richtig, diese Datei nicht.
        //
        // Der Schluesselbundeintrag selbst traegt `ThisDeviceOnly` und bleibt
        // aus fremden Sicherungen heraus. Ohne diese Zeile haette die Abschrift
        // daneben genau den Schutz nicht, den das Original hat — eine
        // Sicherung waehrend einer laufenden Sitzung naehme sie mit. Dieselbe
        // Zeile steht aus demselben Grund auf dem Downloadordner.
        var werte = URLResourceValues()
        werte.isExcludedFromBackup = true
        try? datei.setResourceValues(werte)
        bescheidGeben()
    }

    /// **Dem System sagen, dass sich das Regal geaendert hat.**
    ///
    /// Ohne diese Zeile schrieb die App die Datei, und niemand fragte danach:
    /// tvOS befragt die Erweiterung von sich aus nur selten und merkt sich die
    /// letzte Antwort. Fiel die erste Frage in die Zeit, bevor ueberhaupt
    /// Daten dalagen, blieb der Startbildschirm bei „leer" stehen — und zwar
    /// dauerhaft, bis irgendwann zufaellig neu gefragt wurde. Genau so sah es
    /// bei Paul aus: meistens nur das Zeichen, manchmal das richtige Regal
    /// (17.09.2026).
    private static func bescheidGeben() {
        #if os(tvOS)
        NotificationCenter.default.post(name: NSNotification.Name.TVTopShelfItemsDidChange,
                                        object: nil)
        #endif
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
        // Auch das Leeren muss ankommen: sonst zeigt der Startbildschirm nach
        // dem Abmelden weiter die Titel des vorigen Kontos.
        bescheidGeben()
    }

    static func lesen() -> Regalvorschau? {
        guard let datei, let daten = try? Data(contentsOf: datei) else { return nil }
        return try? JSONDecoder().decode(Regalvorschau.self, from: daten)
    }
}
