import AppKit
import JellyfinKit
import SwiftUI
import XCTest

/// Renders the real macOS SwiftUI screens offscreen from fixtures into PNGs (1280x800 @2x), the SwiftUI half of
/// `cargo xtask swiftui-parity`. Output: `$SWIFTUI_PARITY_OUT` or `<repo>/build/swiftui-parity`, one file per screen,
/// named like the Rust goldens (`home_desktop_initial.png`). Titles are the Rust demo server's.
@MainActor
final class ParitySnapshots: XCTestCase {
    static let out: URL = {
        if let p = ProcessInfo.processInfo.environment["SWIFTUI_PARITY_OUT"] { return URL(fileURLWithPath: p) }
        // Tests/SwiftUIParity/<file> -> repo root
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/swiftui-parity")
    }()

    /// The same signed-in account as the Rust demo (`home_data`): name "Swiftly" on "tv.example.test", with the downloads
    /// switch on (so the sidebar shows "Meins": Merkliste + Downloads and the account footer).
    func makeModel(server: ParityServer? = nil, signedIn: Bool = true) -> AppModel {
        let model = AppModel()
        if signedIn {
            model.session = Session(accessToken: "parity", userID: "u1", userName: "Swiftly",
                                    serverURL: server?.url ?? URL(string: "https://tv.example.test")!)
        }
        model.serverName = "tv.example.test"
        model.downloadsAn = true
        model.watchlistShown = true
        return model
    }

    override func setUp() async throws {
        Keychain.snapshotBlind = true
    }

    // MARK: fixtures (the same JSON as the Rust demo server: home_data.rs and browse.rs)

    static let names = ["Nordlicht", "Sommerregen", "Die Brücke", "Der Weg zurück", "Stilles Wasser", "Letzte Ausfahrt",
                        "Papierschiffe", "Das andere Ufer", "Winterlicht", "Halbe Wahrheit", "Ein ruhiger Ort",
                        "Fremde Küste", "Goldener Herbst", "Nachtzug"]

    func decode(_ raw: String) throws -> Item { try JSONDecoder().decode(Item.self, from: Data(raw.utf8)) }

    /// `home_data::movie`.
    func movie(_ i: Int, resume: Bool = false) throws -> Item {
        let user: String
        switch i % 5 {
        case 1: user = #""UserData":{"Played":true,"IsFavorite":true}"#
        case 2: user = #""UserData":{"Played":true}"#
        default:
            user = resume ? #""UserData":{"PlaybackPositionTicks":\#((i + 2) * 3_000_000_000),"PlayedPercentage":\#(20 + (i * 13) % 60).0,"Played":false}"#
                          : #""UserData":{"Played":false}"#
        }
        return try decode(#"{"Id":"m\#(i)","Name":"\#(Self.names[i % 14])","Type":"Movie","ProductionYear":\#(2015 + i % 10),"RunTimeTicks":54000000000,"Overview":"Ein ruhiger Abend, ein altes Haus und ein Geheimnis, das niemand mehr aussprechen will.","Genres":["Drama"],"ImageTags":{"Primary":"p-m\#(i)"},"BackdropImageTags":["b-m\#(i)"],\#(user)}"#)
    }

    /// `home_data::episode`.
    func episode(_ i: Int) throws -> Item {
        try decode(#"{"Id":"e\#(i)","Name":"Folge \#(i)","Type":"Episode","SeriesId":"s\#(i)","SeriesName":"\#(Self.names[(i + 5) % 14])","ParentIndexNumber":\#(1 + i % 3),"IndexNumber":\#(2 + i),"RunTimeTicks":27000000000,"ImageTags":{"Primary":"p-e\#(i)"},"BackdropImageTags":["b-e\#(i)"],"UserData":{"PlaybackPositionTicks":\#((i + 1) * 2_000_000_000),"PlayedPercentage":\#(15 + (i * 17) % 70).0,"Played":false}}"#)
    }

    /// `home_data::series`.
    func series(_ i: Int) throws -> Item {
        try decode(#"{"Id":"s\#(i)","Name":"\#(Self.names[(i + 7) % 14])","Type":"Series","ProductionYear":\#(2018 + i % 6),"ChildCount":3,"ImageTags":{"Primary":"p-s\#(i)"},"UserData":{"UnplayedItemCount":\#(1 + i % 9),"Played":false}}"#)
    }

    /// `browse::item`.
    func shelfItem(_ i: Int, series: Bool) throws -> Item {
        let user: String
        switch i % 6 {
        case 1: user = #""UserData":{"Played":true,"IsFavorite":true}"#
        case 2: user = #""UserData":{"Played":true}"#
        case 3: user = #""UserData":{"PlaybackPositionTicks":\#((i + 2) * 3_000_000_000),"PlayedPercentage":\#(20 + (i * 13) % 60).0,"Played":false}"#
        default: user = #""UserData":{"Played":false}"#
        }
        return try decode(#"{"Id":"x\#(i)","Name":"\#(Self.names[i % 14])","Type":"\#(series ? "Series" : "Movie")","ProductionYear":\#(2008 + i % 16),"ChildCount":3,"RunTimeTicks":54000000000,"ImageTags":{"Primary":"p-x\#(i)"},\#(user)}"#)
    }

    // MARK: deterministic pictures (a port of crates/swiftly-desktop/src/art.rs)

    private func hsv(_ hue: Float, _ s: Float, _ v: Float) -> [Float] {
        let h = hue - (hue / 1).rounded(.down)
        let sector = h * 6
        let i = sector.rounded(.down), f = sector - i
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(i) {
        case 0: return [v, t, p]
        case 1: return [q, v, p]
        case 2: return [p, v, t]
        case 3: return [p, q, v]
        case 4: return [t, p, v]
        default: return [v, p, q]
        }
    }

    private func gradient(_ w: Int, _ h: Int, variant: Int, count: Int) -> CGImage {
        let hue = Float(variant) / Float(count)
        let a = hsv(hue, 0.65, 0.85)
        let b = hsv(hue + 0.12 + 0.05 * Float(variant % 3), 0.75, 0.35)
        let angle = 0.5 + 0.9 * (Float(variant * 5 % 7) / 7)
        let (ca, sa) = (cos(angle), sin(angle))
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (u, v) = (Float(x) / Float(w), Float(y) / Float(h))
                let t = min(max((u - 0.5) * ca + (v - 0.5) * sa + 0.5, 0), 1)
                let (dx, dy) = (u - 0.3, v - 0.25)
                let glow = exp(-(dx * dx + dy * dy) * 9) * 0.35
                let foot = min(max((v - 0.62) / 0.38, 0), 1)
                for c in 0..<3 {
                    let base = a[c] * (1 - t) + b[c] * t
                    px.append(UInt8(min(max((base + glow) * (1 - 0.55 * foot), 0), 1) * 255))
                }
                px.append(255)
            }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// `home::Art::pick`: the hash of the id chooses the picture.
    private func pick(_ id: String, _ count: Int) -> Int {
        var h: UInt64 = 7
        for byte in id.utf8 { h = h &* 31 &+ UInt64(byte) }
        return Int(h % UInt64(count))
    }

    /// Makes every title id show its generated picture, offline: the app model hands out fake addresses and the
    /// image cache already holds the pictures behind them.
    func installArt(ids: [String]) {
        let posters = (0..<48).map { gradient(116, 174, variant: $0, count: 48) }
        let heroes = (0..<6).map { gradient(640, 200, variant: $0, count: 6) }
        AppModel.snapshotImageURL = { item, portrait in
            URL(string: "https://parity.invalid/\(item.id)/\(portrait ? "p" : "l")")
        }
        for id in ids {
            ImageCache.shared.seedForSnapshot(posters[pick(id, 48)], for: URL(string: "https://parity.invalid/\(id)/p")!)
            ImageCache.shared.seedForSnapshot(heroes[pick(id, 6)], for: URL(string: "https://parity.invalid/\(id)/l")!)
        }
    }

    var allIDs: [String] {
        (0..<30).flatMap { ["m\($0)", "e\($0)", "s\($0)", "x\($0)"] }
    }

    // MARK: rendering

    func render<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 1280, height: 800), scale: CGFloat = 2, settle: TimeInterval = 0.4) throws {
        let root = view.frame(width: size.width, height: size.height)
            .background(Color(red: 0.067, green: 0.067, blue: 0.067))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return XCTFail("rep") }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: Self.out.appendingPathComponent("\(name).png"))
    }

    private struct Window<Content: View>: View {
        let model: AppModel
        let section: Region
        let content: Content
        let nav: Navigator
        let controls: PlayControls
        var body: some View {
            HStack(spacing: 0) {
                Sidebar(model: model, section: .constant(section), adopt: {}, toProfile: {}, sectionSelect: { _ in })
                    .ignoresSafeArea(.container, edges: .vertical)
                Rectangle().fill(Theme.line).frame(width: 1)
                content
            }
            .environment(controls).environment(nav).environment(\.section, section)
        }
    }

    private func window<C: View>(_ section: Region, _ model: AppModel, @ViewBuilder _ content: () -> C) -> some View {
        Window(model: model, section: section, content: content(), nav: Navigator(), controls: PlayControls(model: model))
    }

    // MARK: a Jellyfin-shaped server for the pages the Rust core loads (the mirror of `title_data.rs`)

    nonisolated static func pickID(_ id: String, _ count: Int) -> Int {
        var h: UInt64 = 7
        for byte in id.utf8 { h = h &* 31 &+ UInt64(byte) }
        return Int(h % UInt64(count))
    }

    func makeServer() throws -> ParityServer {
        func png(_ image: CGImage) -> Data {
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
        }
        let posters = (0..<48).map { png(gradient(116, 174, variant: $0, count: 48)) }
        let heroes = (0..<6).map { png(gradient(640, 200, variant: $0, count: 6)) }
        let server = try ParityServer { id, portrait in
            portrait ? posters[Self.pickID(id, 48)] : heroes[Self.pickID(id, 6)]
        }
        try server.start()
        return server
    }

    static let overview = "Als im Hafen von Nordlicht ein altes Schiff ohne Besatzung anlegt, beginnt für die Lotsin Mara eine Suche, die sie weiter von zu Hause wegführt, als sie wollte. Je mehr sie über die Ladung erfährt, desto weniger weiß sie, wem sie trauen kann."

    static var people: String {
        let names = [("Mara Brandt", "Lotsin"), ("Jonas Keller", "Kapitän"), ("Ilse Vogel", "Hafenmeisterin"), ("Tom Albers", "Zöllner"),
                     ("Nina Sommer", "Reporterin"), ("Paul Rath", "Matrose"), ("Eva Lund", "Ärztin")]
        var all = names.enumerated().map { #"{"Id":"p\#($0.offset)","Name":"\#($0.element.0)","Type":"Actor","Role":"\#($0.element.1)","PrimaryImageTag":"t\#($0.offset)"}"# }
        all.append(#"{"Id":"d1","Name":"Anna Weiß","Type":"Director"}"#)
        return all.joined(separator: ",")
    }

    /// `title_data::film_for`.
    func film(sources: Bool, id: String = "m1", name: String = "Nordlicht") -> String {
        let media = sources ? #","MediaSources":[{"Id":"s4k","Name":"4K","Container":"mkv","Size":8400000000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"MediaStreams":[{"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"BitRate":24000000,"RealFrameRate":24.0,"VideoRange":"HDR","Index":0},{"Type":"Audio","Codec":"eac3","Channels":6,"Language":"deu","Index":1,"DisplayTitle":"Deutsch - EAC3 - 5.1"},{"Type":"Audio","Codec":"aac","Channels":2,"Language":"eng","Index":2,"DisplayTitle":"English - AAC - Stereo"},{"Type":"Subtitle","Codec":"subrip","Language":"deu","Index":3}]},{"Id":"s1080","Name":"1080p","Container":"mp4","Size":3100000000,"SupportsDirectPlay":true,"MediaStreams":[]}]"# : ""
        return #"{"Id":"\#(id)","Name":"\#(name)","Type":"Movie","ProductionYear":2021,"RunTimeTicks":54000000000,"Genres":["Drama","Krimi"],"Overview":"\#(Self.overview)","CommunityRating":7.5,"OfficialRating":"12","ImageTags":{"Primary":"p"},"BackdropImageTags":["b"],"People":[\#(Self.people)],"UserData":{"PlaybackPositionTicks":19200000000,"PlayedPercentage":35.5,"Played":false,"IsFavorite":false}\#(media)}"#
    }

    func similarMovies() -> [String] {
        let names = ["Sommerregen", "Die Brücke", "Stilles Wasser", "Letzte Ausfahrt", "Papierschiffe", "Winterlicht", "Fremde Küste", "Nachtzug"]
        return (0..<8).map { #"{"Id":"o\#($0)","Name":"\#(names[$0 % 8])","Type":"Movie","ProductionYear":\#(2012 + $0),"RunTimeTicks":54000000000,"ImageTags":{"Primary":"p\#($0)"},"UserData":{"Played":false}}"# }
    }

    /// The film page's server (`title_data::detail_transport`).
    func detailServer(offline: Bool = false) throws -> ParityServer {
        let server = try makeServer()
        server.offline = offline
        server.route("/Similar", ParityServer.list(similarMovies()))
        server.route("/SpecialFeatures", #"[{"Id":"x1","Name":"Making of","Type":"Video","RunTimeTicks":9000000000},{"Id":"x2","Name":"Geschnittene Szenen","Type":"Video","RunTimeTicks":6000000000}]"#)
        server.route("PlaybackInfo", #"{"PlaySessionId":"x","MediaSources":[{"Id":"s4k","Name":"4K","Container":"mkv","SupportsDirectPlay":true,"SupportsDirectStream":true,"MediaStreams":[{"Type":"Video","Codec":"hevc","Index":0}]}]}"#)
        server.route("/Items/m1", film(sources: true))
        server.route("/Items", ParityServer.list([]))
        return server
    }

    /// The series page's server (`title_data::series_transport`).
    func seriesServer(offline: Bool = false) throws -> ParityServer {
        let server = try makeServer()
        server.offline = offline
        let seasons = (1...3).map { #"{"Id":"se\#($0)","Name":"Staffel \#($0)","Type":"Season","IndexNumber":\#($0),"SeriesId":"ser"}"# }
        let titles = ["Ankunft", "Das Schiff", "Ladung", "Nebel", "Verrat", "Gezeiten", "Landgang", "Der letzte Hafen"]
        func ep(_ n: Int) -> String {
            let user: String
            switch n {
            case 1, 2: user = #""UserData":{"Played":true}"#
            case 3: user = #""UserData":{"PlaybackPositionTicks":9000000000,"PlayedPercentage":42.0,"Played":false}"#
            default: user = #""UserData":{"Played":false}"#
            }
            return #"{"Id":"e\#(n)","Name":"\#(titles[(n - 1) % 8])","Type":"Episode","IndexNumber":\#(n),"ParentIndexNumber":1,"SeasonId":"se1","SeriesId":"ser","Overview":"Mara folgt einer Spur, die im Nebel endet.","RunTimeTicks":27000000000,"ImageTags":{"Primary":"p\#(n)"},\#(user)}"#
        }
        let series = #"{"Id":"ser","Name":"Nordlicht","Type":"Series","ProductionYear":2021,"Genres":["Drama","Krimi"],"Overview":"\#(Self.overview)","CommunityRating":8.1,"OfficialRating":"12","ChildCount":3,"ImageTags":{"Primary":"p"},"BackdropImageTags":["b"],"People":[\#(Self.people)],"UserData":{"UnplayedItemCount":6,"Played":false,"IsFavorite":true}}"#
        server.route("/Items/ser", series)
        server.route("Shows/NextUp", ParityServer.list([ep(3)]))
        server.route("Shows/ser/Seasons", ParityServer.list(seasons))
        server.route("Shows/ser/Episodes", ParityServer.list((1...8).map(ep)))
        server.route("/Similar", ParityServer.list(Array(similarMovies().prefix(6))))
        server.route("/SpecialFeatures", "[]")
        server.route("/Items", ParityServer.list([]))
        return server
    }

    /// A page without the sidebar (the Rust page goldens are the page alone).
    private func page<C: View>(_ model: AppModel, _ content: () -> C) -> some View {
        content().environment(PlayControls(model: model)).environment(Navigator()).environment(\.section, .movies)
    }

    // MARK: screens

    func testHome() throws {
        installArt(ids: allIDs)
        let model = makeModel()
        let home = HomeModel()
        let resume = try [movie(3, resume: true), movie(8, resume: true)] + (1...3).map { try episode($0) } + [4, 8, 12].map { try movie($0, resume: true) }
        home.seedForSnapshot(
            continueWatching: resume,
            nextEpisode: try (4..<9).map { try episode($0) },
            recent: try (0..<14).map { $0 % 4 == 3 ? try series($0) : try movie($0) })
        try render("home_desktop_initial", window(.start, model) { HomeView(model: model, state: home) })
    }

    func testLibrary() throws {
        installArt(ids: allIDs)
        let model = makeModel()
        let shelf = LibraryModel()
        shelf.seedForSnapshot(try (0..<24).map { try shelfItem($0, series: $0 % 5 == 4) })
        try render("library_desktop_initial", window(.movies, model) {
            LibraryView(model: model, art: "movies", title: "Filme", shelf: shelf, choice: .constant(.all))
        })
    }

    func testSearch() throws {
        let model = makeModel()
        try render("search_desktop_hint", window(.search, model) { SearchView(model: model) })
    }

    func testSettings() throws {
        // The debug rows of the "Swiftly" group do not exist in release builds: not part of the page being measured.
        MacSupportSettingsGroup.snapshotWithoutDebugRows = true
        let model = makeModel()
        // The Rust demo's Allgemein page has the downloads switch off (its rows below the switch are not there).
        model.downloadsAn = false
        // `settings_suite_general`: Settings > Allgemein inside the window (sidebar + content column).
        try render("settings_suite_general", window(.start, model) { SettingsView(model: model, back: {}) })
        model.downloadsAn = true
        // `settings_desktop_initial` is the profile hub, the page alone.
        try render("settings_desktop_initial", page(model) { ProfileView(model: model, back: {}) })
        // Sub-pages the Rust suite shoots alone.
        try render("settings_desktop_presentation", page(model) { PresentationView(model: model, back: {}) })
        try render("settings_desktop_playback", page(model) { PlaybackSettingsView(model: model, back: {}) })
    }

    func testDownloads() throws {
        let model = makeModel()
        try render("downloads_desktop_empty", window(.downloads, model) { DownloadsView(model: model) })
        try render("downloads_suite_empty", window(.downloads, model) { DownloadsView(model: model) })
    }

    /// Downloads with sample rows, the same ones as `Scenario::Parity` in `downloads_screen.rs` (ids, titles, sizes, states).
    /// The rows come in through the parity bundle's copy of `DownloadManager` (writable `entries`, a picture hook; see
    /// `Werkzeuge/parity-project.py`), so the app sources carry no seam.
    func testDownloadsFilled() throws {
        let posters = (0..<48).map { gradient(116, 174, variant: $0, count: 48) }
        for id in ["p1", "p2", "p3", "p4", "s1"] {
            ImageCache.shared.seedForSnapshot(posters[pick(id, 48)], for: URL(string: "https://parity.invalid/\(id)/p")!)
        }
        DownloadManager.snapshotImage = { p, group in
            URL(string: "https://parity.invalid/\(group ? (p.seriesIdentifier ?? p.id) : p.id)/p")
        }
        defer { DownloadManager.snapshotImage = nil }
        func entry(_ id: String, _ title: String, bytes: Int64, loaded: Int64, state: String, at: Double,
                   episode: Int? = nil, container: String? = nil) throws -> DownloadItem {
            let kind = episode.map { #","art":"folge","serie":"Die Nachbarn","serienId":"s1","staffel":1,"folge":\#($0),"qualitaet":"hd1080""# } ?? #","art":"film""#
            let box = container.map { #","container":"\#($0)""# } ?? ""
            let raw = #"{"id":"\#(id)","konto":"u1"\#(kind),"titel":"\#(title)","bytes":\#(bytes),"geladen":\#(loaded),"stand":"\#(state)","gesehen":false,"angelegt":\#(at),"nochAufDemServer":true\#(box)}"#
            return try JSONDecoder().decode(DownloadItem.self, from: Data(raw.utf8))
        }
        var rows = [
            try entry("p1", "Der lange Weg", bytes: 3_400_000_000, loaded: 1_200_000_000, state: "laedt", at: 10),
            try entry("p2", "Nachts im Zug", bytes: 1_500_000_000, loaded: 0, state: "wartet", at: 11),
            try entry("p3", "Kaputte Kopie", bytes: 900_000_000, loaded: 0, state: "fehler", at: 12),
        ]
        for n in 1...8 {
            rows.append(try entry("e\(n)", "Folge \(n)", bytes: 700_000_000, loaded: 700_000_000, state: "fertig", at: 20 + Double(n), episode: n))
        }
        rows.append(try entry("p4", "Stille Wasser", bytes: 1_800_000_000, loaded: 1_800_000_000, state: "fertig", at: 40, container: "mkv"))
        let model = makeModel()
        model.downloads.entries = rows
        try render("downloads_suite_filled", window(.downloads, model) { DownloadsView(model: model) })
    }

    func testDetail() throws {
        let server = try detailServer()
        defer { server.stop() }
        let model = makeModel(server: server)
        let item = try decode(film(sources: false))
        try render("detail_desktop_initial", page(model) { DetailView(model: model, item: item, back: {}) }, settle: 5)
        server.writeLog(to: Self.out.appendingPathComponent("requests-detail.log"))
    }

    func testDetailOffline() throws {
        let server = try detailServer(offline: true)
        defer { server.stop() }
        let model = makeModel(server: server)
        let item = try decode(film(sources: false))
        try render("detail_desktop_offline", page(model) { DetailView(model: model, item: item, back: {}) }, settle: 5)
    }

    func testSeries() throws {
        let server = try seriesServer()
        defer { server.stop() }
        let model = makeModel(server: server)
        let show = try decode(#"{"Id":"ser","Name":"Nordlicht","Type":"Series","ProductionYear":2021,"ImageTags":{"Primary":"p"},"BackdropImageTags":["b"],"UserData":{"UnplayedItemCount":6,"Played":false,"IsFavorite":true}}"#)
        try render("series_desktop_initial", page(model) { SeriesView(model: model, series: show, back: {}) }, settle: 5)
        server.writeLog(to: Self.out.appendingPathComponent("requests-series.log"))
    }

    func testSeriesOffline() throws {
        let server = try seriesServer(offline: true)
        defer { server.stop() }
        let model = makeModel(server: server)
        let show = try decode(#"{"Id":"ser","Name":"Nordlicht","Type":"Series","ProductionYear":2021,"ImageTags":{"Primary":"p"},"BackdropImageTags":["b"],"UserData":{"UnplayedItemCount":6,"Played":false,"IsFavorite":true}}"#)
        try render("series_desktop_offline", page(model) { SeriesView(model: model, series: show, back: {}) }, settle: 5)
    }

    /// A server for the browse pages: `/Items` answers with 12 titles (the Rust demo's `browse::item`), or the connection drops.
    func browseServer(offline: Bool = false, hits: Bool = true) throws -> ParityServer {
        let server = try makeServer()
        server.offline = offline
        if hits {
            let rows = try (0..<12).map { i -> String in
                let item = try shelfItem(i, series: i % 5 == 4)
                return String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
            }
            server.route("/Items", ParityServer.list(rows))
        }
        return server
    }

    func searchShot(_ name: String, term: String, server: ParityServer) throws {
        WindowOffPull.searchTerm = term
        defer { WindowOffPull.searchTerm = nil }
        let model = makeModel(server: server)
        try render(name, window(.search, model) { SearchView(model: model) }, settle: 4)
    }

    func testSearchResults() throws {
        let server = try browseServer()
        defer { server.stop() }
        try searchShot("search_desktop_results", term: "nord", server: server)
    }

    func testSearchEmpty() throws {
        let server = try browseServer(hits: false)
        defer { server.stop() }
        try searchShot("search_desktop_empty", term: "xyz", server: server)
    }

    func testSearchOffline() throws {
        let server = try browseServer(offline: true)
        defer { server.stop() }
        try searchShot("search_desktop_offline", term: "nord", server: server)
    }

    func testHomeOffline() throws {
        let server = try browseServer(offline: true)
        defer { server.stop() }
        let model = makeModel(server: server)
        let home = HomeModel()
        try render("home_desktop_offline", window(.start, model) { HomeView(model: model, state: home) }, settle: 4)
    }

    func testLibraryOffline() throws {
        let server = try browseServer(offline: true)
        defer { server.stop() }
        let model = makeModel(server: server)
        let shelf = LibraryModel()
        try render("library_desktop_offline", window(.movies, model) {
            LibraryView(model: model, art: "movies", title: "Filme", shelf: shelf, choice: .constant(.all))
        }, settle: 4)
    }

    func testLibraryEmpty() throws {
        let model = makeModel()
        let shelf = LibraryModel()
        shelf.seedForSnapshot([])
        try render("library_desktop_empty", window(.movies, model) {
            LibraryView(model: model, art: "movies", title: "Filme", shelf: shelf, choice: .constant(.all))
        })
    }

    func testLogin() throws {
        // A Jellyfin server usually offers Quick Connect, and so does the Rust demo server: show the "oder" divider.
        AppModel.snapshotQuickConnect = true
        defer { AppModel.snapshotQuickConnect = false }
        let model = makeModel(signedIn: false)
        // The first page of a new install is the address step (`login_desktop_initial`): `ServerView` reached through the
        // kind picker (`back` set), the page the Rust golden ports. `ServerOnboardingView` is the add-server flow.
        try render("login_desktop_initial", ServerView(model: model, back: {})
            .environment(PlayControls(model: model)).environment(Navigator()).environment(\.section, .start))
        // `SignInView` is the sign-in page (user, password), not the address page: the Rust pair is `login_desktop_signin`.
        try render("login_desktop_signin", SignInView(model: model, serverName: "demo.swiftly.test", version: "10.10.3"))
    }
}
