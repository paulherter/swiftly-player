import Foundation

public extension URL {

    /// Die Adresse ohne alles, was nicht ins Protokoll gehört.
    ///
    /// Jellyfin nimmt das Zugangsmerkmal als Abfragewert entgegen — jede
    /// Bild- und Stromadresse trägt `api_key=<Token>` im Klartext. Landet so
    /// eine Adresse im Systemprotokoll, steht das Token in der Konsole jedes
    /// angeschlossenen Rechners und in jedem Sysdiagnose-Bündel. Das Token ist
    /// ein vollwertiger Serverzugang ohne Ablauf.
    ///
    /// Deshalb: Adressen werden ausschließlich hierüber protokolliert.
    var ohneGeheimnis: String {
        guard var teile = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        let geheim: Set<String> = ["api_key", "ApiKey", "X-Emby-Token", "token",
                                   "secret", "Secret", "pw", "Pw", "password"]
        teile.queryItems = teile.queryItems?.map { wert in
            geheim.contains(wert.name)
                ? URLQueryItem(name: wert.name, value: "…")
                : wert
        }
        return teile.url?.absoluteString ?? absoluteString
    }
}

/// **Unter welchem Namen ein Bild gemerkt wird** — G3, Kehrseite.
///
/// Jede Bildadresse trägt `ApiKey`. Nimmt man sie roh als Schlüssel, heisst
/// dasselbe Plakat nach einem Kontowechsel plötzlich anders: der ganze
/// Speicher ist auf einen Schlag kalt, jede Kachel wird neu geholt, und die
/// alten Einträge liegen weiter, bis sie hinten herausfallen. Bei zwei Konten
/// ist das die Hälfte des Platzes.
///
/// **Ein Bild gehört keinem Konto.** Der Server gibt es unter derselben
/// Kennung heraus, und Jellyfins `tag` bleibt im Schlüssel — eine geänderte
/// Fassung fällt also weiterhin auf. Geholt wird mit dem vollen Weg, gemerkt
/// ohne das Merkmal.
///
/// Das ist die andere Hälfte von G3: beim `Serienspeicher` gehört das Konto
/// in den Schlüssel, weil ein `Item` den Sehstand trägt. Ein Bild trägt keinen.
public enum Bildschluessel {

    public static func fuer(_ url: URL) -> String {
        guard var teile = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let werte = teile.queryItems, werte.contains(where: { merkmal($0.name) })
        else { return url.absoluteString }
        teile.queryItems = werte.filter { !merkmal($0.name) }
        return (teile.url ?? url).absoluteString
    }

    private static func merkmal(_ name: String) -> Bool {
        name == "ApiKey" || name == "api_key"
    }
}
