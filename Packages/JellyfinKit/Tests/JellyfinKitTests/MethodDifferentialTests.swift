import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **The per-method differential: every client method the screens use, on one recorded world.**
///
/// `crates/swiftly-library/tests/fixtures/method_diff/world.json` is a small Jellyfin server (made by
/// `make_world.py`). The router below answers it; the Rust twin is `tests/common/world.rs`. Each
/// method is called here with the real Swift code, and the result (item signatures, in order) is the
/// golden `golden/method_diff/swift_expected.json`; `tests/method_differential.rs` must reproduce it.
/// Record again with `SWIFTLY_RECORD_GOLDEN=1 swift test --filter MethodDifferentialTests`.
/// The recorded state is Apple's: it is compared on Apple platforms only. The Rust core checks the same world
/// on every platform (`crates/swiftly-vm/tests/method_differential.rs`).
private let recordedWithAppleFoundation: Bool = {
    #if canImport(Darwin)
    true
    #else
    false
    #endif
}()

@Suite("Clientmethoden gegen die aufgezeichnete Welt", .serialized)
struct MethodDifferentialTests {

    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("crates/swiftly-library/tests")

    final class World: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var world: [String: Any] = [:]
        nonisolated(unsafe) static var catalog: [[String: Any]] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        static func entry(_ id: String) -> [String: Any]? { catalog.first { $0["Id"] as? String == id } }
        static func list(_ key: String, _ id: String) -> [String] {
            ((world[key] as? [String: Any])?[id] as? [String]) ?? []
        }
        static func descendants(_ id: String) -> [String] {
            list("children", id).flatMap { [$0] + descendants($0) }
        }
        static func wrap(_ list: [[String: Any]]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["Items": list, "TotalRecordCount": list.count])
        }
        static func key(_ e: [String: Any], _ field: String) -> String {
            switch field {
            case "SortName": return ((e["SortName"] as? String) ?? (e["Name"] as? String) ?? "").lowercased()
            case "DateCreated": return (e["DateCreated"] as? String) ?? ""
            default: return ""
            }
        }
        static func year(_ e: [String: Any]) -> Double { (e["ProductionYear"] as? NSNumber)?.doubleValue ?? 0 }

        override func startLoading() {
            let url = request.url!
            let q = Dictionary(
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .map { ($0.name.lowercased(), $0.value ?? "") },
                uniquingKeysWith: { a, _ in a })
            let parts = url.path.split(separator: "/").map(String.init)
            var status = 200
            var body = Self.wrap([])
            func ids(_ list: [String]) -> [[String: Any]] { list.compactMap { Self.entry($0) } }
            func limited(_ l: [[String: Any]]) -> [[String: Any]] { Array(l.prefix(Int(q["limit"] ?? "") ?? l.count)) }
            let last = parts.last ?? ""
            func played(_ e: [String: Any]) -> Bool { ((e["UserData"] as? [String: Any])?["Played"] as? Bool) ?? false }

            if last == "UserViews" {
                body = Self.wrap(Self.world["views"] as! [[String: Any]])
            } else if parts.suffix(2) == ["UserItems", "Resume"] {
                body = Self.wrap(limited(ids(Self.world["resume"] as! [String])))
            } else if parts.suffix(2) == ["Shows", "NextUp"] {
                let l = q["seriesid"].map { Self.list("nextup_series", $0) } ?? (Self.world["nextup"] as! [String])
                body = Self.wrap(limited(ids(l)))
            } else if last == "Ancestors" {
                let list = (Self.world["ancestors"] as? [String: Any])?[parts[parts.count - 2]] as? [[String: Any]] ?? []
                body = try! JSONSerialization.data(withJSONObject: list)
            } else if last == "Seasons", parts.count >= 3, parts[parts.count - 3] == "Shows" {
                body = Self.wrap(ids(Self.list("seasons", parts[parts.count - 2])))
            } else if last == "Episodes", parts.count >= 3, parts[parts.count - 3] == "Shows" {
                var l = ids(Self.list("episodes", parts[parts.count - 2]))
                if let s = q["seasonid"] { l = l.filter { $0["SeasonId"] as? String == s } }
                if (q["filters"] ?? "").split(separator: ",").contains("IsUnplayed") { l = l.filter { !played($0) } }
                if let adj = q["adjacentto"], let at = l.firstIndex(where: { $0["Id"] as? String == adj }) {
                    l = Array(l[max(at - 1, 0)...min(at + 1, l.count - 1)])
                }
                body = Self.wrap(limited(l))
            } else if last == "Similar" {
                body = Self.wrap(limited(ids(Self.list("similar", parts[parts.count - 2]))))
            } else if last == "SpecialFeatures" || last == "LocalTrailers" {
                let l = ids(Self.list(last == "SpecialFeatures" ? "extras" : "trailers", parts[parts.count - 2]))
                body = try! JSONSerialization.data(withJSONObject: l)
            } else if last == "Items", parts.count >= 3, parts[parts.count - 3] == "Playlists" {
                body = Self.wrap(limited(ids(Self.list("playlists", parts[parts.count - 2]))))
            } else if last == "Genres" {
                body = Self.wrap(Self.world["genres"] as! [[String: Any]])
            } else if last == "Items" {
                var pool: [[String: Any]]
                if let want = q["ids"] {
                    let set = Set(want.split(separator: ",").map(String.init))
                    pool = Self.catalog.filter { set.contains($0["Id"] as? String ?? "") }
                } else if let p = q["parentid"] {
                    pool = ids(q["recursive"] == "true" ? Self.descendants(p) : Self.list("children", p))
                } else { pool = Self.catalog }
                if let t = q["includeitemtypes"], !t.isEmpty {
                    let set = Set(t.split(separator: ",").map(String.init))
                    pool = pool.filter { set.contains($0["Type"] as? String ?? "") }
                }
                if let term = q["searchterm"], !term.isEmpty {
                    pool = pool.filter { ($0["Name"] as? String ?? "").lowercased().contains(term.lowercased()) }
                }
                for f in (q["filters"] ?? "").split(separator: ",").map(String.init) {
                    let user: ([String: Any]) -> [String: Any] = { ($0["UserData"] as? [String: Any]) ?? [:] }
                    switch f {
                    case "IsFavorite": pool = pool.filter { user($0)["IsFavorite"] as? Bool == true }
                    case "IsPlayed": pool = pool.filter { played($0) }
                    case "IsUnplayed": pool = pool.filter { !played($0) }
                    case "IsResumable": pool = pool.filter { (user($0)["PlaybackPositionTicks"] as? NSNumber)?.int64Value ?? 0 > 0 }
                    default: break
                    }
                }
                if let p = q["isplayed"] { pool = pool.filter { played($0) == (p == "true") } }
                if let g = q["genres"] {
                    let want = Set(g.split(separator: "|").map(String.init))
                    pool = pool.filter { !want.isDisjoint(with: Set(($0["Genres"] as? [String]) ?? [])) }
                }
                if let p = q["personids"] {
                    let want = Set(p.split(separator: ",").map(String.init))
                    pool = pool.filter {
                        let have = (($0["People"] as? [[String: Any]]) ?? []).compactMap { $0["Id"] as? String }
                        return !want.isDisjoint(with: Set(have))
                    }
                }
                let sortBy = q["sortby"] ?? ""
                let desc = q["sortorder"] == "Descending"
                if ["SortName", "DateCreated", "ProductionYear,SortName"].contains(sortBy) {
                    let indexed = Array(pool.enumerated())
                    let sorted = indexed.sorted { a, b in
                        let c: Int
                        if sortBy == "ProductionYear,SortName" {
                            let ya = Self.year(a.element), yb = Self.year(b.element)
                            if ya != yb { c = ya < yb ? -1 : 1 } else {
                                c = Self.cmp(Self.key(a.element, "SortName"), Self.key(b.element, "SortName"))
                            }
                        } else {
                            c = Self.cmp(Self.key(a.element, sortBy), Self.key(b.element, sortBy))
                        }
                        if c == 0 { return a.offset < b.offset }
                        return desc ? c > 0 : c < 0
                    }
                    pool = sorted.map(\.element)
                }
                let total = pool.count
                let start = Int(q["startindex"] ?? "") ?? 0
                pool = Array(pool.dropFirst(start))
                pool = limited(pool)
                body = try! JSONSerialization.data(withJSONObject: ["Items": pool, "TotalRecordCount": total])
            } else if parts.count >= 2, parts[parts.count - 2] == "Items" {
                if let e = Self.entry(last) { body = try! JSONSerialization.data(withJSONObject: e) } else { status = 404 }
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func cmp(_ a: String, _ b: String) -> Int {
            let x = Array(a.utf8), y = Array(b.utf8)
            if x == y { return 0 }
            return x.lexicographicallyPrecedes(y) ? -1 : 1
        }
    }

    private func client() async -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [World.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "dev", deviceName: "Test",
                               urlSession: URLSession(configuration: config))
        await c.setSession(Session(accessToken: "tok", userID: "u1", userName: "t",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    // MARK: signatures

    static func num(_ d: Double?) -> String {
        guard let d else { return "-" }
        return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }
    static func sig(_ i: Item) -> String {
        let u = i.userData
        let fields: [String] = [
            i.id, i.name, i.type ?? "-", i.productionYear.map(String.init) ?? "-",
            i.runTimeTicks.map(String.init) ?? "-", i.indexNumber.map(String.init) ?? "-",
            i.parentIndexNumber.map(String.init) ?? "-", i.sortName ?? "-",
            u?.played.map { $0 ? "P" : "u" } ?? "-", u?.isFavorite.map { $0 ? "F" : "n" } ?? "-",
            num(u?.playedPercentage), u?.playbackPositionTicks.map(String.init) ?? "-",
            num(i.communityRating), i.childCount.map(String.init) ?? "-",
            (i.genres ?? []).joined(separator: ";"),
            (i.providerIds ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"),
            i.seriesId ?? "-", i.seasonId ?? "-",
        ]
        return fields.joined(separator: "|")
    }
    static func sigs(_ l: [Item]) -> [String] { l.map(sig) }
    static func page(_ r: ItemsResponse) -> [String: Any] { ["items": sigs(r.items), "total": r.totalRecordCount] }

    private func record(_ name: String, _ out: inout [String: Any], _ body: () async throws -> Any?) async {
        do { out[name] = try await body() ?? "NIL" } catch { out[name] = "ERR" }
    }

    // MARK: the test

    @Test("Jede Clientmethode gleicht dem aufgezeichneten Stand",
          .enabled(if: recordedWithAppleFoundation, "the state was recorded with Apple's Foundation; the Linux Foundation orders some texts differently"))
    func methods() async throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("fixtures/method_diff/world.json"))
        World.world = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        World.catalog = World.world["catalog"] as! [[String: Any]]
        let c = await client()
        var r: [String: Any] = [:]
        r["locale"] = Locale.current.language.languageCode?.identifier ?? "en"

        await record("views", &r) { Self.sigs(try await c.userViews()) }
        await record("views_hidden", &r) { Self.sigs(try await c.userViews(hidden: true)) }

        // library pages
        for (n, start) in [0, 7, 14, 21, 28, 35, 100].enumerated() {
            await record("page_movies_\(n)", &r) {
                Self.page(try await c.items(parentID: "L-MOV", limit: 7, startIndex: start, recursive: true,
                                            includeItemTypes: ["Movie"]))
            }
        }
        await record("page_desc_created", &r) {
            Self.page(try await c.items(parentID: "L-MOV", limit: 10, sortBy: "DateCreated", sortOrder: "Descending",
                                        recursive: true, includeItemTypes: ["Movie"]))
        }
        await record("page_unwatched", &r) {
            Self.page(try await c.items(parentID: "L-MOV", limit: 50, isWatched: false, recursive: true,
                                        includeItemTypes: ["Movie"]))
        }
        await record("page_watched", &r) {
            Self.page(try await c.items(parentID: "L-MOV", limit: 50, isWatched: true, recursive: true,
                                        includeItemTypes: ["Movie"]))
        }
        await record("page_favorites", &r) {
            Self.page(try await c.items(limit: 50, filters: ["IsFavorite"], recursive: true,
                                        includeItemTypes: ["Movie", "Series"]))
        }
        await record("page_resumable", &r) {
            Self.page(try await c.items(limit: 50, filters: ["IsResumable"], recursive: true,
                                        includeItemTypes: ["Movie"]))
        }
        await record("page_series", &r) {
            Self.page(try await c.items(parentID: "L-TV", limit: 50, recursive: true, includeItemTypes: ["Series"]))
        }
        await record("page_series_nonrec", &r) {
            Self.page(try await c.items(parentID: "L-TV", limit: 50))
        }
        await record("page_genre_comma", &r) {
            Self.page(try await c.items(limit: 50, recursive: true, includeItemTypes: ["Movie", "Series"],
                                        genres: ["Action,Adventure"]))
        }
        await record("page_person", &r) {
            Self.page(try await c.items(limit: 50, sortBy: "ProductionYear,SortName", sortOrder: "Descending",
                                        recursive: true, includeItemTypes: ["Movie", "Series"], personIDs: ["p1"]))
        }
        await record("page_slim", &r) {
            Self.page(try await c.items(parentID: "L-MOV", limit: 3, recursive: true, includeItemTypes: ["Movie"], slim: true))
        }
        await record("page_ids", &r) {
            Self.page(try await c.items(limit: 5, ids: ["m05", "w01", "w02", "w03", "w04", "w05", "w06", "w07", "w08", "nope"]))
        }
        await record("count_movies", &r) { try await c.count(parentID: "L-MOV", types: ["Movie"]) }
        await record("count_mix_series", &r) { try await c.count(parentID: "L-MIX", types: ["Series"]) }
        await record("title_ids", &r) { Self.sigs(try await c.titleIds(parentID: "L-MOV", types: ["Movie"], filters: ["IsFavorite"])) }
        await record("title_ids_unwatched", &r) { Self.sigs(try await c.titleIds(parentID: "L-MOV", types: ["Movie"], isWatched: false)) }
        await record("identifiers", &r) { Self.sigs(try await c.identifiers(ids: ["s0", "s1", "m00b", "w05"])) }
        await record("ancestors", &r) { Self.sigs(try await c.preTravel(from: "m00b")) }

        // natural order and its pages
        await record("natural_list", &r) {
            Self.sigs(try await c.naturalList(parentID: "L-MOV", sortOrder: "Ascending", filters: [], isWatched: nil,
                                              recursive: true, includeItemTypes: ["Movie"]))
        }
        await record("natural_list_desc", &r) {
            Self.sigs(try await c.naturalList(parentID: "L-MOV", sortOrder: "Descending", filters: ["IsFavorite"],
                                              isWatched: nil, recursive: true, includeItemTypes: ["Movie"]))
        }
        await record("natural_pages", &r) {
            let list = try await c.naturalList(parentID: "L-MOV", sortOrder: "Ascending", filters: [], isWatched: nil,
                                               recursive: true, includeItemTypes: ["Movie"])
            return [Self.page(try await c.naturalPage(list, since: 0, count: 6)),
                    Self.page(try await c.naturalPage(list, since: 6, count: 9)),
                    Self.page(try await c.naturalPage(list, since: 28, count: 100)),
                    Self.page(try await c.naturalPage(list, since: 500, count: 10))]
        }

        // search: one hit per work, natural order
        for term in ["a", "x-men", "the", "ice", "", "zzz", "wire"] {
            await record("search_\(term)", &r) { Self.sigs(try await c.search(term, limit: 40)) }
        }
        await record("search_limit3", &r) { Self.sigs(try await c.search("e", limit: 3)) }

        // series, seasons, episodes, specials
        await record("seasons_s0", &r) { Self.sigs(try await c.seasons(seriesID: "s0")) }
        await record("seasons_none", &r) { Self.sigs(try await c.seasons(seriesID: "nope")) }
        await record("episodes_s1", &r) { Self.sigs(try await c.episodes(seriesID: "s1")) }
        await record("episodes_s1_season2", &r) { Self.sigs(try await c.episodes(seriesID: "s1", seasonID: "s1-2")) }
        await record("episodes_s1_specials", &r) { Self.sigs(try await c.episodes(seriesID: "s1", seasonID: "s1-0")) }
        await record("first_episode", &r) { try await c.firstEpisode(seriesID: "s0").map(Self.sig) }
        await record("first_episode_none", &r) { try await c.firstEpisode(seriesID: "nope").map(Self.sig) }
        await record("next_s0", &r) { try await c.nextEpisodeSeries(seriesID: "s0").map(Self.sig) }
        await record("next_s1", &r) { try await c.nextEpisodeSeries(seriesID: "s1").map(Self.sig) }
        await record("post_mid", &r) { try await c.episodePost(itemID: "s1-2-3", seriesID: "s1").map(Self.sig) }
        await record("post_s2e10", &r) { try await c.episodePost(itemID: "s1-2-10", seriesID: "s1").map(Self.sig) }
        await record("post_last", &r) { try await c.episodePost(itemID: "s1-2-11", seriesID: "s1").map(Self.sig) }
        await record("post_unknown", &r) { try await c.episodePost(itemID: "zz", seriesID: "s1").map(Self.sig) }
        await record("state_s0", &r) { try await c.stateInSeriesChecked("s0").map(Self.sig) }
        await record("state_s1", &r) { try await c.stateInSeriesChecked("s1").map(Self.sig) }
        await record("state_none", &r) { try await c.stateInSeriesChecked("nope").map(Self.sig) }
        await record("resume", &r) { Self.sigs(try await c.resumeItems(limit: 20)) }
        await record("next_up", &r) { Self.sigs(try await c.nextUp(limit: 20)) }

        // similar, extras, trailers
        let own = try await c.item(id: "m00")
        await record("similar_m00", &r) { Self.sigs(try await c.similar(itemID: "m00", toward: own, limit: 12)) }
        await record("similar_m00_plain", &r) { Self.sigs(try await c.similar(itemID: "m00", limit: 3)) }
        await record("similar_s0", &r) { Self.sigs(try await c.similar(itemID: "s0", toward: try await c.item(id: "s0"), limit: 12)) }
        await record("extras", &r) { Self.sigs(try await c.extras(itemID: "m00")) }
        await record("trailers", &r) { Self.sigs(try await c.trailer(toward: "m00")) }

        // collections, playlists
        await record("collection_members", &r) { Self.sigs(try await c.collectionMembers("bs1")) }
        await record("collection_directory", &r) {
            let d = try await c.collectionDirectory(viewList: try await c.userViews())
            return d.all.map { [$0.item.id, $0.movies.sorted(), $0.seriesList.sorted()] as [Any] }
        }
        await record("playlist_entries", &r) { Self.sigs(try await c.playlistEntries("pl1")) }
        await record("playlist_entries_lean", &r) { Self.sigs(try await c.playlistEntries("pl1", lean: true)) }
        await record("playlist_entries_audio", &r) { Self.sigs(try await c.playlistEntries("pl2")) }
        await record("playlist_directory", &r) {
            let d = try await c.playlistDirectory()
            return d.all.map { [$0.item.id, $0.movies, $0.episodes] as [Any] }
        }
        await record("library_shares", &r) {
            let s = await c.libraryShares(views: try await c.userViews())
            return Dictionary(uniqueKeysWithValues: s.map { ($0.key, [$0.value.movies, $0.value.seriesList]) })
        }

        // genres, people
        await record("genres", &r) { try await c.genres() }
        await record("title_genre", &r) { await c.title(genre: "Action", limit: 24).map(Self.sigs) }
        await record("title_genre_comma", &r) { await c.title(genre: "Action,Adventure", limit: 24).map(Self.sigs) }
        await record("title_person", &r) { await c.title(person: "p1", limit: 60).map(Self.sigs) }
        for (n, start) in [0, 5, 10].enumerated() {
            await record("title_person_n\(n)", &r) {
                guard let x = await c.titleWithNumber(person: "p1", limit: 5, startIndex: start) else { return nil }
                return ["items": Self.sigs(x.items), "total": x.total] as [String: Any]
            }
            await record("title_genre_n\(n)", &r) {
                guard let x = await c.titleWithNumber(genre: "Action", limit: 5, startIndex: start) else { return nil }
                return ["items": Self.sigs(x.items), "total": x.total] as [String: Any]
            }
        }

        // watchlist, duplicates, version merging
        await record("remembered_ids", &r) {
            Self.sigs(try await c.rememberedIds(types: ["Movie", "Series"], sortBy: "SortName", sortOrder: "Ascending"))
        }
        for (n, start) in [0, 3, 6, 40].enumerated() {
            await record("remembered_\(n)", &r) {
                Self.page(try await c.rememberedItems(types: ["Movie", "Series"], sortBy: "SortName",
                                                      sortOrder: "Ascending", startIndex: start, limit: 3))
            }
        }
        let everything = World.catalog.compactMap { try? JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: $0)) }
        r["decoded_ids"] = everything.map(\.id)
        for per in [false, true] {
            await record("in_times_\(per)", &r) { Self.sigs(await c.jeItemInTimes(everything, episodesPerSeries: per)) }
            await record("in_times_movies_\(per)", &r) {
                Self.sigs(await c.jeItemInTimes(everything.filter { $0.type == "Movie" }, episodesPerSeries: per))
            }
            await record("in_times_episodes_\(per)", &r) {
                Self.sigs(await c.jeItemInTimes(everything.filter { $0.type == "Episode" }, episodesPerSeries: per))
            }
        }
        r["without_double"] = Self.sigs(ListRules.withoutDouble(everything))
        r["title_in_times"] = Self.sigs(ListRules.jeTitleInTimes(everything, showItem: 40))
        r["series_in_times"] = Self.sigs(ListRules.jeSeriesInTimes(everything.filter { $0.type == "Episode" }))
        r["with_double_ep"] = Self.sigs(Items.withDouble(everything, seriesList: [:], episodesPerSeries: true))
        r["with_double_ep_false"] = Self.sigs(Items.withDouble(everything, seriesList: [:], episodesPerSeries: false))

        let golden = Self.root.appendingPathComponent("golden/method_diff/swift_expected.json")
        let out = try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["SWIFTLY_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: golden)
        } else {
            let want = try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as! NSDictionary
            #expect(want.isEqual(to: r))
        }
    }
}
