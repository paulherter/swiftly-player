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
                throw JellyfinError.transport(uebersetzt("Der Server hat Quick Connect abgeschaltet."))
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
    /// eigener Fall (``Quickconnectabgelaufen``), keine Netzstoerung: dann
    /// holt man sich einen neuen Code. Wer nachfragt, nimmt
    /// ``quickConnectNachfragen(_:)`` — dort ist die Unterscheidung schon getroffen.
    public func quickConnectFreigegeben(_ vorgang: Anmeldecode) async throws -> Bool {
        struct Antwort: Decodable { let Authenticated: Bool }
        let req = try rohAnfrage("QuickConnect/Connect", method: "GET",
                                 query: [.init(name: "secret", value: vorgang.geheimnis)])
        let (daten, antwort) = try await rohSitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse else { return false }
        if http.statusCode == 404 { throw Quickconnectabgelaufen() }
        guard http.statusCode == 200 else { return false }
        return (try? JSONDecoder().decode(Antwort.self, from: daten))?.Authenticated ?? false
    }

    /// **Einmal nachfragen, ohne dass ein Netzfehler das Warten beendet.**
    ///
    /// Beim Warten wechselt der Nutzer fast immer die App — er tippt den Code
    /// ja im Browser ein. Android und iOS legen die App dann schlafen; die
    /// laufende Abfrage bricht ab („Software caused connection abort",
    /// Zeitueberschreitung, Namensaufloesung). Das sagt nichts ueber den Code.
    /// Vorher beendete genau so ein Fehler das Warten und stand roh auf dem
    /// Schirm, obwohl der Code noch galt.
    public func quickConnectNachfragen(_ vorgang: Anmeldecode) async -> Quickconnectstand {
        do {
            return try await quickConnectFreigegeben(vorgang) ? .freigegeben : .offen
        } catch {
            return Quickconnectstand(fehler: error)
        }
    }

    /// Holt sich das Zugangsmerkmal, nachdem der Code freigegeben wurde.
    public func anmeldenMitQuickConnect(_ vorgang: Anmeldecode) async throws -> Session {
        struct Rumpf: Encodable { let Secret: String }
        return try await anmeldenMit(rumpf: Rumpf(Secret: vorgang.geheimnis),
                                     an: "Users/AuthenticateWithQuickConnect")
    }
}

/// **Wie lange auf eine Quick-Connect-Freigabe gewartet wird, und in welchem
/// Takt.**
///
/// Die Zahlen standen dreimal: in `QuickConnectModell` auf Apple und
/// **zweimal** auf Linux — einmal beim Erstanmelden, einmal beim Hinzufuegen
/// eines Kontos. Drei Bauplaetze fuer dieselbe Frist laufen auseinander,
/// sobald jemand an einem dreht.
public enum Quickconnectfrist {

    /// **Fuenf Minuten.** So lange haelt Jellyfin den Code; laenger zu warten
    /// hiesse, auf etwas zu warten, das es nicht mehr gibt.
    public static let sekunden = 300

    /// **Alle zwei Sekunden fragen.** Schneller belastet den Server ohne
    /// Gewinn — freigegeben wird von Hand, und niemand tippt in unter zwei
    /// Sekunden einen sechsstelligen Code ab.
    public static let takt = 2

    /// Wie viele Abfragen daraus folgen.
    public static var versuche: Int { sekunden / takt }

    /// **Was am Ende der Frist dasteht.** Scheiterte schon die letzte
    /// Abfrage, lag es nicht am Code, sondern an der Verbindung — dann sagt
    /// die Meldung das auch.
    public static func schlusstext(letzte: Quickconnectstand) -> String {
        letzte == .gescheitert ? uebersetzt("Der Server hat nicht geantwortet.")
                               : uebersetzt("Der Code ist abgelaufen. Hol dir einen neuen.")
    }
}

/// Der Server kennt den Quick-Connect-Vorgang nicht mehr (404).
public struct Quickconnectabgelaufen: LocalizedError, Equatable, Sendable {
    public init() {}
    public var errorDescription: String? {
        uebersetzt("Der Code ist abgelaufen. Hol dir einen neuen.")
    }
}

/// **Das Ergebnis einer Nachfrage beim Warten auf die Freigabe.**
///
/// Nur `freigegeben` und `abgelaufen` beenden das Warten. `gescheitert` heisst:
/// diese eine Abfrage kam nicht durch — weiter fragen, der Code gilt noch.
public enum Quickconnectstand: String, Sendable, Equatable {
    case offen, freigegeben, abgelaufen, gescheitert

    public init(fehler: any Error) {
        self = fehler is Quickconnectabgelaufen ? .abgelaufen : .gescheitert
    }

    /// Ob das Warten hier endet.
    public var beendetWarten: Bool { self == .freigegeben || self == .abgelaufen }
}
