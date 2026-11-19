import Foundation

/// What the Seerr screens ask of the media server: which library item carries a TMDB id, and a new scan.
extension JellyfinClient {

    /// The id of the library item (film or series) whose `ProviderIds.Tmdb` is `tmdb`, `nil` when the
    /// server has none. The server filters (`AnyProviderIdEquals`); the answer is checked again here, so
    /// a server that ignores the filter cannot hand back an unrelated title.
    public func itemID(tmdb: Int, series: Bool) async throws -> String? {
        try await itemID(tmdb: tmdb, kind: series ? "Series" : "Movie")
    }

    /// The same for any item kind that carries a TMDB id (`Movie`, `Series`, `Person`, `BoxSet`): the
    /// search shows a person or collection hit of Seerr only when the own server has it.
    public func itemID(tmdb: Int, kind: String) async throws -> String? {
        let s = try requireSessionForReporting()
        let req = try rawRequest("Items", method: "GET", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: kind),
            .init(name: "AnyProviderIdEquals", value: "tmdb.\(tmdb)"),
            .init(name: "Fields", value: "ProviderIds"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"),
            .init(name: "Limit", value: "200"),
        ])
        let data = try await answer(for: req)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]] else { return nil }
        return items.first { item in
            (item["Type"] as? String).map { $0 == kind } ?? true
                && (item["ProviderIds"] as? [String: Any]).flatMap { ids in
                    (ids["Tmdb"] ?? ids["tmdb"]).flatMap { "\($0)" }
                } == String(tmdb)
        }?["Id"] as? String
    }

    /// Asks the server to scan its libraries again (`POST /Library/Refresh`, needs an administrator).
    public func scanLibraries() async throws {
        _ = try requireSessionForReporting()
        _ = try await answer(for: try rawRequest("Library/Refresh", method: "POST"))
    }

    /// The checked body of an answer; a refusal or a failure throws.
    private func answer(for req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await rawSession.data(for: req)
        } catch {
            throw JellyfinError(petition: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode, body: String(data: data.prefix(300), encoding: .utf8))
        }
        return data
    }
}
