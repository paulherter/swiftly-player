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

    func render<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 1280, height: 800), scale: CGFloat = 2) throws {
        let root = view.frame(width: size.width, height: size.height)
            .background(Color(red: 0.067, green: 0.067, blue: 0.067))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
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

    // MARK: screens

    func testHome() throws {
        installArt(ids: allIDs)
        let model = AppModel()
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
        let model = AppModel()
        let shelf = LibraryModel()
        shelf.seedForSnapshot(try (0..<24).map { try shelfItem($0, series: $0 % 5 == 4) })
        try render("library_desktop_initial", window(.movies, model) {
            LibraryView(model: model, art: "movies", title: "Filme", shelf: shelf, choice: .constant(.all))
        })
    }

    func testSearch() throws {
        let model = AppModel()
        try render("search_desktop_hint", window(.search, model) { SearchView(model: model) })
    }

    func testSettings() throws {
        // The debug rows of the "Swiftly" group do not exist in release builds: not part of the page being measured.
        MacSupportSettingsGroup.snapshotWithoutDebugRows = true
        let model = AppModel()
        // Fair pair: the Rust suite opens Settings > Allgemein (`settings_suite_general`). The old name stays, compared with
        // the Rust profile hub, as the history line.
        try render("settings_desktop_initial", window(.start, model) { SettingsView(model: model, back: {}) })
        try render("settings_suite_general", window(.start, model) { SettingsView(model: model, back: {}) })
    }

    func testDownloads() throws {
        let model = AppModel()
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
        let model = AppModel()
        model.downloads.entries = rows
        try render("downloads_suite_filled", window(.downloads, model) { DownloadsView(model: model) })
    }

    func testDetail() throws {
        installArt(ids: allIDs)
        let model = AppModel()
        let item = try movie(3, resume: true)
        try render("detail_desktop_initial", window(.movies, model) { DetailView(model: model, item: item, back: {}) })
    }

    func testSeries() throws {
        installArt(ids: allIDs)
        AppModel.snapshotSeries = (
            seasons: try (1...3).map { try decode(#"{"Id":"se\#($0)","Name":"Staffel \#($0)","Type":"Season","IndexNumber":\#($0),"SeriesId":"s1","ImageTags":{"Primary":"p-se\#($0)"}}"#) },
            episodes: try (1...8).map { try decode(#"{"Id":"e\#($0)","Name":"\#(Self.names[$0 % 14])","Type":"Episode","SeriesId":"s1","ParentIndexNumber":1,"IndexNumber":\#($0),"RunTimeTicks":27000000000,"Overview":"Zwischen Hafen und Hinterhof erzählt die Folge von Freundschaft, Schulden und der Frage, was ein Zuhause ausmacht.","ImageTags":{"Primary":"p-e\#($0)"},"UserData":{"Played":\#($0 < 3)}}"#) })
        defer { AppModel.snapshotSeries = nil }
        let model = AppModel()
        let show = try series(1)
        try render("series_desktop_initial", window(.seriesList, model) { SeriesView(model: model, series: show, back: {}) })
    }

    func testLogin() throws {
        // A Jellyfin server usually offers Quick Connect, and so does the Rust demo server: show the "oder" divider.
        AppModel.snapshotQuickConnect = true
        defer { AppModel.snapshotQuickConnect = false }
        let model = AppModel()
        // `SignInView` is the sign-in page (user, password), not the address page: the Rust pair is `login_desktop_signin`.
        try render("login_desktop_initial", SignInView(model: model, serverName: "demo.swiftly.test", version: "10.10.3"))
        try render("login_desktop_signin", SignInView(model: model, serverName: "demo.swiftly.test", version: "10.10.3"))
    }
}
