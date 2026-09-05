import Foundation
import JellyfinKit
import Observation

/// Die Anbindung an Jellyseerr oder Overseerr, aus Sicht der Oberfläche.
///
/// **Eine Zugabe, kein Fundament.** Wer nichts angebunden hat, soll von
/// alldem nichts sehen — keine leere Rubrik, keine graue Schaltfläche, keinen
/// Hinweis, dass ihm etwas entgeht. Deshalb beantwortet dieses Modell vor
/// allem eine Frage, und alle Ansichten fragen sie: ``verbunden``.
///
/// **Und es hält die Suche nicht auf.** Sucht jemand, laufen die eigene
/// Bibliothek und Seerr nebeneinander; kommt von Seerr nichts oder kommt es
/// spät, steht trotzdem sofort da, was der eigene Server hat. Genau daran
/// hing am 05.09.2026 der Riegel im Folgenwechsel — eine Zugabe darf nie das
/// Eigene blockieren.
@MainActor
@Observable
final class Seerrmodell {

    /// Wo der Zugang liegt. Eigener Schlüssel, damit ein Abmelden von
    /// Jellyfin die Seerr-Anmeldung nicht mitnimmt — es sind zwei Dienste.
    private static let schluessel = "seerr"

    private(set) var zugang: Seerrzugang?
    private(set) var traegt = false
    private(set) var fehler: String?

    /// Läuft eine Anmeldung? Die Ansicht sperrt damit ihren Knopf.
    private(set) var meldetAn = false

    var verbunden: Bool { zugang != nil }
    var adresse: String? { zugang?.adresse.absoluteString }

    private var client: SeerrClient? {
        zugang.map { SeerrClient(zugang: $0) }
    }

    init() { zugang = geladen() }

    // MARK: Verbinden

    /// Anmelden und den Zugang sichern.
    ///
    /// **Der Benutzername kommt aus der Jellyfin-Anmeldung**, das Passwort
    /// tippt der Nutzer — wir haben es nicht, und das soll so bleiben. Es
    /// wird auch nicht gespeichert: gesichert wird nur die Sitzung, die
    /// Seerr daraufhin ausstellt.
    func verbinden(adresse eingabe: String, benutzer: String, passwort: String) async {
        fehler = nil
        guard let url = Seerr.adresse(aus: eingabe) else {
            fehler = String(localized: "Diese Adresse ergibt keine.")
            return
        }
        meldetAn = true
        defer { meldetAn = false }
        do {
            let neu = try await SeerrClient.anmelden(an: url, benutzer: benutzer,
                                                     passwort: passwort)
            sichern(neu)
            zugang = neu
            traegt = true
        } catch {
            fehler = error.localizedDescription
        }
    }

    /// Trennen. Nur unsere Seite — bei Seerr selbst bleibt alles, wie es ist.
    func trennen() {
        Keychain.delete(key: Self.schluessel)
        zugang = nil
        traegt = false
        fehler = nil
    }

    /// Beim Öffnen der Einstellungen: gilt die Sitzung noch?
    ///
    /// Sitzungen laufen ab, und ein Nutzer soll das an der Zeile sehen und
    /// nicht erst beim nächsten Anfragen.
    func nachsehen() async {
        guard let client else { return }
        traegt = await client.gilt()
    }

    // MARK: Benutzen

    /// Suchen — **ohne zu werfen und ohne aufzuhalten.**
    func suchen(_ begriff: String) async -> [Seerrtreffer] {
        guard let client, Anzeigeregeln.suchbegriffTaugt(begriff) else { return [] }
        return await client.suchen(begriff)
    }

    /// Beschreibung, Bewertung und Staffeln — für die Seite eines Titels.
    func detail(_ treffer: Seerrtreffer) async -> Seerrdetail? {
        guard let client else { return nil }
        return await client.detail(art: treffer.art, id: treffer.id)
    }

    /// Anfragen. Hier wird geworfen: der Nutzer hat gedrückt.
    func anfragen(_ treffer: Seerrtreffer, staffeln: [Int]? = nil) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        try await client.anfragen(art: treffer.art, id: treffer.id, staffeln: staffeln)
    }

    // MARK: Ablage

    private func geladen() -> Seerrzugang? {
        guard let daten = Keychain.load(key: Self.schluessel) else { return nil }
        return try? JSONDecoder().decode(Seerrzugang.self, from: daten)
    }

    private func sichern(_ z: Seerrzugang) {
        guard let daten = try? JSONEncoder().encode(z) else { return }
        // **In den Schlüsselbund, nicht in die Einstellungen.** Der Keks ist
        // ein Zugang zu einem Dienst, der Titel anfordern kann.
        try? Keychain.save(daten, key: Self.schluessel)
    }
}
