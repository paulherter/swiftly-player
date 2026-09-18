import Foundation
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem
// eigenen Modul. Auf Apple-Plattformen gibt es das Modul nicht — der
// Import ist deshalb bedingt und dort wirkungslos.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Quick Connect: einen Code freigeben, der auf einem anderen Gerät steht.
///
/// Der Ablauf ist umgekehrt zu dem, was der Name nahelegt. Nicht dieses Gerät
/// meldet sich an — der Fernseher zeigt einen sechsstelligen Code, und dieses
/// bereits angemeldete Gerät gibt ihn frei. Deshalb sitzt es im Profilmenü und
/// nicht auf der Anmeldeseite.
extension JellyfinClient {

    /// Ob der Server Quick Connect überhaupt anbietet. Er kann es abschalten,
    /// dann antwortet er mit 503 statt mit `false`.
    public func quickConnectVerfuegbar() async -> Bool {
        guard let req = try? rohAnfrage("QuickConnect/Enabled", method: "GET"),
              let (daten, antwort) = try? await rohSitzung.data(for: req),
              let http = antwort as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        return String(data: daten, encoding: .utf8)?.lowercased().contains("true") ?? false
    }

    /// Gibt den Code frei. Wirft mit lesbarem Grund, damit die Oberfläche
    /// nicht „Fehler" anzeigen muss.
    public func quickConnectFreigeben(code: String) async throws {
        let sitzung = try requireSessionForReporting()
        let sauber = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sauber.count >= 4 else { throw JellyfinError.transport("Der Code ist zu kurz.") }

        let req = try rohAnfrage(
            "QuickConnect/Authorize", method: "POST",
            query: [URLQueryItem(name: "code", value: sauber),
                    URLQueryItem(name: "userId", value: sitzung.userID)])

        let (daten, antwort) = try await rohSitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort vom Server.")
        }
        switch http.statusCode {
        case 200:
            // Der Server antwortet mit true oder false, nicht mit einem Fehler.
            let text = String(data: daten, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("false") {
                throw JellyfinError.transport("Der Code ist abgelaufen oder falsch.")
            }
        case 403:
            throw JellyfinError.transport("Dein Konto darf Quick Connect nicht freigeben.")
        case 503:
            throw JellyfinError.transport("Der Server hat Quick Connect abgeschaltet.")
        default:
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: daten.prefix(200), encoding: .utf8))
        }
    }
}
