import Foundation
import Testing
@testable import JellyfinKit

/// A server with two series libraries: "Kids" holds old titles, "Serien" new ones. The
/// lists must come out in the order asked for across both, not one library after the other.
@Suite("Plex: mehrere Bibliotheken als eine Liste")
struct PlexMergeTests {
    private struct Entry {
        let id: String, title: String, added: Int, year: Int
    }

    // Each library's answer is sorted by addedAt descending, as the server does.
    private let kids = [Entry(id: "k1", title: "Kinderserie A", added: 1_000, year: 2010),
                        Entry(id: "k2", title: "Kinderserie B", added: 900, year: 2012)]
    private let serien = [Entry(id: "s1", title: "Neue Serie", added: 5_000, year: 2024),
                          Entry(id: "s2", title: "Mittlere Serie", added: 3_000, year: 2020),
                          Entry(id: "s3", title: "Alte Serie", added: 800, year: 2001)]

    private func body(_ entries: [Entry], total: Int, start: Int, size: Int, byName: Bool) -> String {
        let sorted = byName ? entries.sorted { $0.title < $1.title } : entries
        let slice = sorted.dropFirst(start).prefix(size)
        let rows = slice.map {
            #"{"ratingKey":"\#($0.id)","type":"show","title":"\#($0.title)","addedAt":\#($0.added),"year":\#($0.year)}"#
        }.joined(separator: ",")
        return #"{"MediaContainer":{"size":\#(slice.count),"totalSize":\#(total),"Metadata":[\#(rows)]}}"#
    }

    private func client() -> (PlexClient, String) {
        let (host, session) = PlexStub.register { [self] request in
            let path = request.url?.path ?? ""
            let start = Int(request.value(forHTTPHeaderField: "X-Plex-Container-Start") ?? "") ?? 0
            let size = Int(request.value(forHTTPHeaderField: "X-Plex-Container-Size") ?? "") ?? 100
            let sort = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "sort" }?.value ?? ""
            let byName = sort.hasPrefix("titleSort")
            switch path {
            case "/library/sections":
                return (200, #"{"MediaContainer":{"size":2,"Directory":[{"key":"1","type":"show","title":"Kids","uuid":"a"},{"key":"2","type":"show","title":"Serien","uuid":"b"}]}}"#)
            case "/library/sections/1/all", "/library/sections/1/recentlyAdded":
                return (200, body(kids, total: kids.count, start: start, size: size, byName: byName))
            case "/library/sections/2/all", "/library/sections/2/recentlyAdded":
                return (200, body(serien, total: serien.count, start: start, size: size, byName: byName))
            default:
                return (404, "")
            }
        }
        let identity = PlexIdentity(clientID: "cid", platform: "macOS", device: "Mac", deviceName: "T")
        return (PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "TOK",
                           identity: identity, urlSession: session), host)
    }

    @Test("Neueste zuerst: die neue Serie steht vor den alten Kinderserien")
    func newestAcrossLibraries() async throws {
        let (client, _) = client()
        let page = try await client.items(limit: 10, sortBy: "DateCreated", sortOrder: "Descending",
                                          recursive: true, includeItemTypes: ["Series"])
        #expect(page.items.map(\.id) == ["s1", "s2", "k1", "k2", "s3"])
        #expect(page.totalRecordCount == 5)
    }

    @Test("Eine spätere Seite setzt die gemischte Reihenfolge fort")
    func paging() async throws {
        let (client, _) = client()
        let second = try await client.items(limit: 2, startIndex: 2, sortBy: "DateCreated",
                                            sortOrder: "Descending", recursive: true,
                                            includeItemTypes: ["Series"])
        #expect(second.items.map(\.id) == ["k1", "k2"])
        #expect(second.totalRecordCount == 5)
    }

    @Test("Nach Namen sortiert mischt sich ebenfalls")
    func byName() async throws {
        let (client, _) = client()
        let page = try await client.items(limit: 10, sortBy: "SortName", sortOrder: "Ascending",
                                          recursive: true, includeItemTypes: ["Series"])
        #expect(page.items.map(\.name) == ["Alte Serie", "Kinderserie A", "Kinderserie B",
                                           "Mittlere Serie", "Neue Serie"])
    }

    @Test("Neu hinzugefügt über alle Bibliotheken nach Zeitpunkt, nicht reihum")
    func lastAddedByTime() async throws {
        let (client, _) = client()
        let items = try #require(await client.lastAdded(in: nil, fetch: 20, showItem: 4,
                                                        genres: "Series"))
        #expect(items.map(\.id) == ["s1", "s2", "k1", "k2"])
        let series = try #require(await client.newSeries(in: nil, showItem: 3))
        #expect(series.map(\.id) == ["s1", "s2", "k1"])
    }

    @Test("Zufällig oder unbekannt bleibt Bibliothek für Bibliothek")
    func unorderedStays() throws {
        let a = [try meta("1", added: 1)], b = [try meta("2", added: 9)]
        #expect(PlexMerge.merged([a, b], sort: "random").map(\.ratingKey) == ["1", "2"])
        #expect(PlexMerge.merged([a, b], sort: nil).map(\.ratingKey) == ["1", "2"])
        #expect(PlexMerge.merged([a, b], sort: "addedAt:desc").map(\.ratingKey) == ["2", "1"])
    }

    @Test("Fenster: nur der Teil jeder Bibliothek, der die Seite erreichen kann")
    func windowRanges() {
        // 5000 + 50 titles, page at 4000: the big run skips what is surely before the page.
        let w = PlexMerge.window(totals: [5000, 50], start: 4000, size: 60)
        #expect(w.ranges == [3950..<4060, 0..<50])
        #expect(w.skipped == 3950)
        // Start beyond the end: nothing to fetch.
        let past = PlexMerge.window(totals: [3, 2], start: 40, size: 10)
        #expect(past.ranges.allSatisfy { $0.isEmpty })
        // Single page at the start: from 0 up to size, capped by the run.
        #expect(PlexMerge.window(totals: [100, 4], start: 0, size: 10).ranges == [0..<10, 0..<4])
    }

    @Test("Fenster-Seite entspricht jeder Seite der vollen Mischung")
    func windowedPageEqualsFullMerge() throws {
        let sort = "addedAt:desc"
        let totals = [37, 5, 22]
        // Distinct, strictly descending addedAt per run, interleaved across runs.
        var runs: [[PlexMetadata]] = []
        for (library, total) in totals.enumerated() {
            runs.append(try (0..<total).map { n in
                try meta("\(library)-\(n)", added: 1_000 - (n * 3 + library))
            })
        }
        let full = PlexMerge.merged(runs, sort: sort).map(\.ratingKey)
        for start in [0, 1, 7, 20, 31, 40, 63, 64, 70] {
            for size in [1, 6, 25] {
                let w = PlexMerge.window(totals: totals, start: start, size: size)
                let parts = zip(runs, w.ranges).map { Array($0.0[$0.1]) }
                let got = PlexMerge.page(parts, skipped: w.skipped, sort: sort, start: start, size: size)
                #expect(got.map(\.ratingKey) == Array(full.dropFirst(start).prefix(size)),
                        "start \(start) size \(size)")
            }
        }
    }

    private func meta(_ id: String, added: Int) throws -> PlexMetadata {
        let json = #"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"\#(id)","type":"show","title":"t\#(id)","addedAt":\#(added)}]}}"#
        return try #require(JSONDecoder().decode(PlexEnvelope<PlexListing>.self, from: Data(json.utf8))
            .container.metadata.first)
    }
}
