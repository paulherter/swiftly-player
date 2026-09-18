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
            // **Nicht zusätzlich laden, wenn es ein Wechsel war.** Dann
            // räumt `sitzungUebernehmen` bereits auf und stösst das Neuladen
            // an; ein zweiter Lauf daneben liefert sich mit dem ersten ein
            // Rennen, und wer verliert, schreibt Halbfertiges.
            if !sitzungUebernehmen(s) { await loadViews() }
        } catch {
            errorMessage = lesbar(error)
        }
    }

    /// Fehler so, wie man sie jemandem sagen würde.
    ///
    /// **Liegt jetzt im Paket** (``lesbarerFehler(_:)``). Er hing hier an
    /// `String(localized:)` mit dem App-Katalog und war damit fuer die
    /// Linux-Fassung unerreichbar — dort stand bei jeder fehlgeschlagenen
    /// Anmeldung roh `error.localizedDescription`, was gegen D3 verstoesst.
    func lesbar(_ fehler: any Error) -> String { lesbarerFehler(fehler) }
}
