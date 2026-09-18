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
