import Foundation
import OSLog
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

    // MARK: - Eigene Header (Issue #4)

    /// Ein Eintrag für alle Server: die ganze Tafel aus ``Eigenkoepfe``.
    private static let koepfeSchluessel = "eigenkoepfe"

    /// Beim Start, vor der ersten Anfrage.
    static func eigeneKoepfeLaden() {
        Eigenkoepfe.laden(Keychain.load(key: koepfeSchluessel))
    }

    /// Was für einen Server eingetragen ist — für „Erweitert".
    func eigeneKoepfe(fuer server: URL?) -> [Eigenkopf] {
        server.map(Eigenkoepfe.eingetragen(fuer:)) ?? []
    }

    /// Setzen und ablegen. Eine leere Liste nimmt den Server heraus.
    ///
    /// **In den Schlüsselbund, nicht in die Einstellungen** — die Werte sind
    /// Zugänge wie das Merkmal selbst. Und ins Protokoll gehen nur die Namen.
    func eigeneKoepfeSichern(_ koepfe: [Eigenkopf], fuer server: URL) {
        Eigenkoepfe.setzen(koepfe, fuer: server)
        let tafel = Eigenkoepfe.ablage()
        if tafel == Data("{}".utf8) {
            Keychain.delete(key: Self.koepfeSchluessel)
        } else {
            try? Keychain.save(tafel, key: Self.koepfeSchluessel)
        }
        let namen = Eigenkoepfe.namen(Eigenkoepfe.eingetragen(fuer: server))
        Self.log.info("Eigene Header gesichert: \(namen, privacy: .public)")
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

    /// Eine Nachfrage, die nie wirft — siehe `Quickconnectwarten` im Paket.
    func quickConnectNachfragen(_ vorgang: Anmeldecode) async -> Quickconnectstand {
        guard let client else { return .gescheitert }
        return await client.quickConnectNachfragen(vorgang)
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

/// Eine Zeile in „Erweitert" — Name und Wert eines eigenen Headers.
///
/// **Eine eigene Kennung, nicht der Index.** Wer die zweite von drei Zeilen
/// entfernt, soll nicht zusehen, wie der Wert der dritten in die zweite
/// rutscht, während er noch tippt.
struct Kopfzeile: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var wert = ""

    /// Den setzt Swiftly selbst — die Zeile sagt es, statt still nichts zu tun.
    var gesperrt: Bool { Eigenkoepfe.istGesperrt(name) }

    static func aus(_ koepfe: [Eigenkopf]) -> [Kopfzeile] {
        koepfe.map { Kopfzeile(name: $0.name, wert: $0.wert) }
    }
}

extension Array where Element == Kopfzeile {
    /// Was davon hinausgehen darf — über dieselbe Schleuse wie überall.
    var koepfe: [Eigenkopf] {
        Eigenkoepfe.bereinigt(map { Eigenkopf(name: $0.name, wert: $0.wert) })
    }
}
