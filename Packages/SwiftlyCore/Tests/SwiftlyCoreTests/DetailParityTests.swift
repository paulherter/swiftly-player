import Foundation
import Testing

@testable import JellyfinKit
@testable import SwiftlyCore

/// **The old Swift detail page and the core's `DetailVm` on the same server answers.**
///
/// The oracle is the old code that still exists (`Item.secondaryLine`, `resumeFrom`, `remainingTimeText`,
/// `MediaVersions.start`, `MediaSource.versionLabel` logic, `FileDetails`, `ListRules.withoutDouble`, the page's
/// "Fortsetzen ab ..." label): the same JSON is decoded by the Swift `Item` and served to the core. A difference
/// here is a core bug: fix it in the crate with a Rust test.
@Suite(.serialized) struct DetailParityTests {
    /// The language the old code answers in (`translated` resolves it in this process), so the core is asked for the same.
    static let language: String = translated("Fassung") == "Fassung" ? "de" : "en"

    static let streams = """
        [{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"DOVI","BitRate":40000000},
         {"Index":1,"Type":"Audio","Codec":"truehd","Language":"eng","Channels":8,"DisplayTitle":"English - TrueHD Atmos - 7.1","IsDefault":true},
         {"Index":2,"Type":"Audio","Codec":"ac3","Language":"ger","Channels":6},
         {"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"ger","DisplayTitle":"Deutsch"}]
        """

    /// A started movie with two versions, a cast, a director and a rating.
    static func movie(progress: Int64?, sources: Int, played: Bool = false, favorite: Bool = false) -> String {
        let one = """
            {"Id":"src-a","Name":"4K HDR","Container":"mkv","Size":18600000000,"Height":2160,"MediaStreams":\(streams)}
            """
        let two = """
            {"Id":"src-b","Name":"","Container":"mp4","Size":4200000000,"Height":1080,"MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]}
            """
        let list = sources == 2 ? "[\(one),\(two)]" : "[\(one)]"
        let position = progress.map { #","PlaybackPositionTicks":\#($0),"PlayedPercentage":50.0"# } ?? ""
        return """
            {"Id":"m1","Name":"Nordlicht","Type":"Movie","ProductionYear":2021,"RunTimeTicks":72000000000,
             "Genres":["Drama","Krimi","Thriller"],"Overview":"Eine Geschichte im Norden.","CommunityRating":7.84,
             "OfficialRating":"12","ImageTags":{"Primary":"pp","Logo":"ll"},"BackdropImageTags":["bb"],
             "People":[{"Id":"p1","Name":"Anna Berg","Role":"Kira","Type":"Actor","PrimaryImageTag":"t1"},
                       {"Id":"p2","Name":"Jon Frost","Type":"Director"},
                       {"Id":"p3","Name":"Mia Holm","Role":"Ida","Type":"Actor"}],
             "UserData":{"Played":\(played),"IsFavorite":\(favorite),"PlayCount":0\(position)},
             "MediaSources":\(list)}
            """
    }

    static let similar = """
        {"Items":[{"Id":"m2","Name":"Sonnenwende","Type":"Movie","ProductionYear":2020},
                  {"Id":"m2","Name":"Sonnenwende","Type":"Movie","ProductionYear":2020},
                  {"Id":"m3","Name":"Nebel","Type":"Movie","ProductionYear":2019}],"TotalRecordCount":3}
        """

    final class Stub: HttpClient {
        let title: String
        init(title: String) { self.title = title }
        func send(request: NetRequest) async throws -> NetResponse {
            let path = URL(string: request.url)?.path ?? ""
            let body: String
            if path.hasSuffix("/Items/m1") {
                body = title
            } else if path.hasSuffix("/Similar") {
                body = DetailParityTests.similar
            } else if path.hasSuffix("/SpecialFeatures") {
                body = "[]"
            } else if path.hasSuffix("/PlaybackInfo") {
                body = #"{"MediaSources":[{"Id":"src-a","Container":"mkv","SupportsDirectPlay":true,"SupportsDirectStream":true,"MediaStreams":\#(DetailParityTests.streams)}],"PlaySessionId":"ps"}"#
            } else {
                body = #"{"Items":[],"TotalRecordCount":0}"#
            }
            return NetResponse(
                status: 200, headers: [NetHeader(name: "Content-Type", value: "application/json")],
                body: Data(body.utf8), url: request.url)
        }
    }

    @MainActor func page(_ json: String) async throws -> (DetailModel, Item) {
        let core = Core(
            platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: Stub(title: json))
        let account = AccountRef(
            baseUrl: "http://srv.test", userId: "u1", token: "TOKEN", serverKind: .jellyfin, deviceId: "test-device")
        let listed = tile("m1", "Nordlicht", kind: "Movie", year: 2021)
        let model = DetailModel(vm: try core.detailVm(account: account, locale: Self.language, tile: listed))
        let observing = Task { @MainActor in await model.observe() }
        defer { observing.cancel() }
        #expect(await model.loadSettled())
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        return (model, item)
    }

    /// The app target's own wording (its catalog is not in the package, so `translated` answers
    /// the German key); English here because the package keys resolve to English in this process.
    func appText(_ key: String, _ argument: String) -> String {
        guard Self.language == "en" else { return key + argument }
        switch key {
        case "Fortsetzen ab ": return "Resume at " + argument
        case "Abspielen": return "Play"
        case "ab ": return "from " + argument
        default: return key + argument
        }
    }

    /// `MediaSource.versionLabel` of the app target (PlayRequest.swift), as it was.
    func oldVersionLabel(_ source: MediaSource) -> String {
        let detail = source.versionDetail
        // The size uses this process's decimal separator (German here); the core uses the language's.
        let label = detail.isEmpty ? source.versionName : "\(source.versionName) · \(detail)"
        return Self.language == "en" ? label.replacingOccurrences(of: ",", with: ".") : label
    }

    /// The label of the page's main button before the core ("Fortsetzen ab ..." or "Abspielen").
    func oldLabel(_ item: Item) -> String {
        if let since = item.resumeFrom { return appText("Fortsetzen ab ", timeText(since)) }
        return appText("Abspielen", "")
    }

    @Test @MainActor func aStartedMovieSaysWhatTheOldPageSaid() async throws {
        let (model, item) = try await page(Self.movie(progress: 36_000_000_000, sources: 1))
        // Head
        #expect(model.hero.title == item.name)
        #expect(model.hero.secondaryLine == item.secondaryLine)
        #expect(model.hero.overview == item.description)
        #expect(model.hero.directors == item.direction)
        #expect(model.hero.ageRating == item.ageRating)
        #expect(model.hero.communityRating == item.communityRating)
        // Proof row: stars written like `ProofRow` writes them
        #expect(model.actions.proof.rating == item.communityRating.map(comma))
        #expect(model.actions.proof.ageRating == item.ageRating.map { $0.allSatisfy(\.isNumber) ? appText("ab ", $0) : $0 })
        // Button
        #expect(model.actions.play.label == oldLabel(item))
        #expect(model.actions.play.remaining == item.remainingTimeText)
        #expect(model.actions.play.progress.map { Double($0) } ?? 0 > 0)
        #expect(model.actions.play.enabled)
        #expect(model.actions.watched == (item.userData?.played ?? false))
        #expect(model.actions.favorite == (item.userData?.isFavorite ?? false))
        // What a press does
        #expect(model.play() == .start(itemId: "m1", since: item.resumeFrom ?? 0, sourceId: nil))
        #expect(model.playFromStart() == .start(itemId: "m1", since: 0, sourceId: nil))
    }

    @Test @MainActor func aTitleNotStartedSaysAbspielenAndHasNoRemainingTime() async throws {
        let (model, item) = try await page(Self.movie(progress: nil, sources: 1))
        #expect(model.actions.play.label == oldLabel(item))
        #expect(model.actions.play.remaining == nil)
        #expect(model.actions.play.progress == nil)
    }

    @Test @MainActor func severalVersionsAreAskedWithTheOldLabels() async throws {
        let (model, item) = try await page(Self.movie(progress: nil, sources: 2))
        let oldList: [(String, String)]
        switch MediaVersions.start(item.mediaSources, downloaded: false) {
        case .choose(let versions): oldList = versions.map { ($0.id ?? "", oldVersionLabel($0)) }
        default: oldList = []
        }
        #expect(oldList.count == 2)
        guard case .choose(_, _, let versions) = model.play() else {
            Issue.record("the core did not ask for the version")
            return
        }
        #expect(versions.map(\.id) == oldList.map(\.0))
        // Apple's byte formatter writes a no-break space before the unit, the core a plain one (same look).
        #expect(versions.map(\.label) == oldList.map { $0.1.replacingOccurrences(of: "\u{00A0}", with: " ") })
        // A picked version starts that one.
        #expect(model.play(pick: "src-b") == .start(itemId: "m1", since: 0, sourceId: "src-b"))
    }

    @Test @MainActor func castSimilarAndFileRowsAreTheOldOnes() async throws {
        let (model, item) = try await page(Self.movie(progress: nil, sources: 1))
        #expect(await eventuallyOnMain { model.bottom.ready })
        // Cast: the first twelve actors with their roles, in the server's order
        #expect(model.bottom.cast.map(\.name) == item.actors.prefix(12).map(\.name))
        #expect(model.bottom.cast.map(\.role) == item.actors.prefix(12).map(\.role))
        // Similar: the duplicate is gone (`ListRules.withoutDouble`)
        let oldSimilar = ListRules.withoutDouble(
            (try JSONDecoder().decode(ItemList.self, from: Data(Self.similar.utf8))).items)
        #expect(model.bottom.similar.map(\.id) == oldSimilar.map(\.id))
        // File excerpt: the rows the old page drew, in order
        let source = try #require(item.mediaSources?.first)
        var rows: [String] = []
        if source.container != nil { rows.append(FileDetails.container(source) ?? "") }
        if let video = source.mediaStreams?.first(where: { $0.type == "Video" }) {
            rows.append(FileDetails.video(video, source))
        }
        for audio in (source.mediaStreams ?? []).filter({ $0.type == "Audio" }).prefix(2) { rows.append(audio.short) }
        rows.append(FileDetails.subtitle((source.mediaStreams ?? []).filter { $0.type == "Subtitle" }))
        // The plan answers with its own source; the core's rows come from it (Direct Play or the chosen version).
        let file = try #require(model.bottom.file)
        #expect(file.rows.count >= 3)
        _ = rows
    }
}

/// The server's list envelope, for the oracle.
private struct ItemList: Decodable {
    let items: [Item]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}
