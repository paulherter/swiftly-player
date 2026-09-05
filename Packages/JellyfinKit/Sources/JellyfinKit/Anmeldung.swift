import Foundation
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem
// eigenen Modul. Auf Apple-Plattformen gibt es das Modul nicht — der
// Import ist deshalb bedingt und dort wirkungslos.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wer auf diesem Server sichtbar ist, noch bevor man angemeldet ist.
public struct OeffentlicherBenutzer: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let bildmarke: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name"
        case bildmarke = "PrimaryImageTag"
    }
}

/// Ein angefangener Quick-Connect-Vorgang.
public struct Anmeldecode: Sendable, Equatable {
    public let code: String
    /// Das Geheimnis bleibt beim Gerät; nur der Code wird vorgelesen.
    public let geheimnis: String
}

extension JellyfinClient {

    /// Die öffentlichen Benutzer des Servers.
    ///
    /// Jellyfin gibt sie ohne Anmeldung heraus, damit ein Anmeldebildschirm
    /// zeigen kann, wer hier überhaupt in Frage kommt. Wer das ignoriert,
    /// lässt den Namen abtippen, den der Server schon kennt.
    public func oeffentlicheBenutzer() async throws -> [OeffentlicherBenutzer] {
        let req = try rohAnfrage("Users/Public", method: "GET")
        let (daten, antwort) = try await rohSitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse, http.statusCode == 200 else {
            // Der Server darf die Liste abschalten. Das ist kein Fehler,
            // sondern heißt nur: dann eben tippen.
            return []
        }
        return (try? JSONDecoder().decode([OeffentlicherBenutzer].self, from: daten)) ?? []
    }

    /// Adresse des Benutzerbildes auf der Anmeldeseite — ohne Anmeldung, also
    /// ohne Token in der Adresse.
    public func benutzerbild(_ benutzer: OeffentlicherBenutzer, kante: Int = 180) -> URL? {
        guard let marke = benutzer.bildmarke else { return nil }
        var teile = URLComponents(url: baseURL.appendingPathComponent("Users/\(benutzer.id)/Images/Primary"),
                                  resolvingAgainstBaseURL: false)
        teile?.queryItems = [.init(name: "tag", value: marke),
                             .init(name: "fillWidth", value: String(kante)),
                             .init(name: "quality", value: "90")]
        return teile?.url
    }

    // MARK: - Quick Connect als Anmeldeweg

    /// Startet einen Vorgang und liefert den Code, den man woanders eingibt.
    ///
    /// Die Gegenrichtung zu `quickConnectFreigeben`: dort gibt dieses Gerät
    /// einen fremden Code frei, hier lässt es sich selbst freigeben. Auf dem
    /// Telefon ist das der bequemere Weg — ein Passwort mit Sonderzeichen
    /// tippt sich auf einer Glasscheibe schlecht.
    public func quickConnectStarten() async throws -> Anmeldecode {
        struct Antwort: Decodable {
            let Secret: String
            let Code: String
        }
        let req = try rohAnfrage("QuickConnect/Initiate", method: "POST")
        let (daten, antwort) = try await rohSitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort vom Server.")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 503 {
                throw JellyfinError.transport("Der Server hat Quick Connect abgeschaltet.")
            }
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: daten.prefix(200), encoding: .utf8))
        }
        let a = try JSONDecoder().decode(Antwort.self, from: daten)
        return Anmeldecode(code: a.Code, geheimnis: a.Secret)
    }

    /// Ob der Code inzwischen freigegeben wurde.
    ///
    /// Antwortet der Server mit 404, ist der Vorgang abgelaufen — das ist ein
    /// eigener Fall, keine Fehlermeldung: dann holt man sich einen neuen Code.
    public func quickConnectFreigegeben(_ vorgang: Anmeldecode) async throws -> Bool {
        struct Antwort: Decodable { let Authenticated: Bool }
        let req = try rohAnfrage("QuickConnect/Connect", method: "GET",
                                 query: [.init(name: "secret", value: vorgang.geheimnis)])
        let (daten, antwort) = try await rohSitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse else { return false }
        if http.statusCode == 404 { throw JellyfinError.transport("Der Code ist abgelaufen.") }
        guard http.statusCode == 200 else { return false }
        return (try? JSONDecoder().decode(Antwort.self, from: daten))?.Authenticated ?? false
    }

    /// Holt sich das Zugangsmerkmal, nachdem der Code freigegeben wurde.
    public func anmeldenMitQuickConnect(_ vorgang: Anmeldecode) async throws -> Session {
        struct Rumpf: Encodable { let Secret: String }
        return try await anmeldenMit(rumpf: Rumpf(Secret: vorgang.geheimnis),
                                     an: "Users/AuthenticateWithQuickConnect")
    }
}
