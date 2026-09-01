import Foundation
import JellyfinKit

/// Was der Anmeldebildschirm über den letzten Server weiß.
struct Servererinnerung: Codable, Equatable {
    let adresse: String
    let name: String
    let version: String
}

extension AppModel {

    // MARK: - Zuletzt verbunden

    private static let erinnerungsSchluessel = "letzterServer"

    /// Beim zweiten Mal tippt niemand die Adresse erneut.
    var letzterServer: Servererinnerung? {
        guard let roh = UserDefaults.standard.data(forKey: Self.erinnerungsSchluessel) else {
            return nil
        }
        return try? JSONDecoder().decode(Servererinnerung.self, from: roh)
    }

    /// Nur der Rechnername, ohne Schema — so, wie man ihn jemandem sagt.
    ///
    /// Aus der Erinnerung und nicht vom Klienten: der ist ein Akteur, und für
    /// eine Zeile Text lohnt kein Sprung über die Akteursgrenze.
    var serverAdresse: String? { letzterServer?.adresse }

    func serverMerken(adresse: String, name: String, version: String) {
        let e = Servererinnerung(adresse: adresse, name: name, version: version)
        guard let roh = try? JSONEncoder().encode(e) else { return }
        UserDefaults.standard.set(roh, forKey: Self.erinnerungsSchluessel)
    }

    // MARK: - Wer schaut

    /// Leer heißt hier nicht „Fehler", sondern „der Server gibt die Liste
    /// nicht her" — dann tippt man den Namen eben.
    func oeffentlicheBenutzer() async -> [OeffentlicherBenutzer] {
        guard let client else { return [] }
        return (try? await client.oeffentlicheBenutzer()) ?? []
    }

    /// Der Bau der Adresse ist reine Rechnung, aber der Klient ist ein Akteur
    /// — also asynchron, und das Ergebnis wird beim Laden der Liste gleich
    /// mitgenommen statt bei jedem Zeichnen neu erfragt.
    func bildAdressen(_ leute: [OeffentlicherBenutzer]) async -> [String: URL] {
        guard let client else { return [:] }
        var karte: [String: URL] = [:]
        for person in leute {
            if let u = await client.benutzerbild(person) { karte[person.id] = u }
        }
        return karte
    }

    // MARK: - Quick Connect als Anmeldeweg

    func quickConnectStarten() async throws -> Anmeldecode {
        guard let client else { throw JellyfinError.notAuthenticated }
        return try await client.quickConnectStarten()
    }

    func quickConnectFreigegeben(_ vorgang: Anmeldecode) async throws -> Bool {
        guard let client else { return false }
        return try await client.quickConnectFreigegeben(vorgang)
    }

    func anmeldenMitQuickConnect(_ vorgang: Anmeldecode) async {
        guard let client else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let s = try await client.anmeldenMitQuickConnect(vorgang)
            sitzungUebernehmen(s)
            await loadViews()
        } catch {
            errorMessage = lesbar(error)
        }
    }

    /// Fehler so, wie man sie jemandem sagen würde.
    ///
    /// `localizedDescription` einer `URLError` ist brauchbar, die eines
    /// selbstgebauten Fehlers ist es selten — dort steht sonst der Typname.
    func lesbar(_ fehler: any Error) -> String {
        if let j = fehler as? JellyfinError {
            switch j {
            case let .transport(text):      return text
            case .notAuthenticated:         return String(localized: "Nicht angemeldet.")
            case .invalidServerURL:         return String(localized: "Die Adresse konnte nicht gelesen werden.")
            case let .http(status, _):
                switch status {
                case 401:  return String(localized: "Benutzername oder Passwort stimmt nicht.")
                case 403:  return String(localized: "Dieses Konto darf das nicht.")
                case 404:  return String(localized: "Das gibt es auf dem Server nicht.")
                case 500...599: return String(localized: "Der Server hat einen Fehler gemeldet.")
                default:   return String(localized: "Der Server hat mit \(status) geantwortet.")
                }
            case let .decoding(text):
                return String(localized: "Die Antwort des Servers war unverständlich. (\(String(text.prefix(80))))")
            }
        }
        if let u = fehler as? URLError {
            switch u.code {
            case .notConnectedToInternet: return String(localized: "Keine Verbindung.")
            case .timedOut:               return String(localized: "Der Server hat nicht geantwortet.")
            case .cannotFindHost, .cannotConnectToHost:
                return String(localized: "Unter dieser Adresse ist kein Server erreichbar.")
            default:                      return u.localizedDescription
            }
        }
        return fehler.localizedDescription
    }
}
