#if DEBUG
import Foundation
import JellyfinKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// **The running-app matrix driver** (DEBUG builds only, nothing of it ships in Release).
///
/// Launch arguments:
///   -SwiftlyFixture <url>        sign in to the fixture server (`cargo run -p xtask -- fixture-server`)
///   -SwiftlyLiveMemory           keep the fixture account in memory only (a device with real accounts)
///   -SwiftlyFixtureKind plex     the account is a Plex one (default Jellyfin)
///   -SwiftlyFixtureUser gast     the account is the fixture's non-administrator (`fixture-server --admin`)
///   -SwiftlyFixtureSeerr         Seerr is connected to the fixture server (it answers `/api/v1`), session cookie
///                                `connect.sid=fixture`, no password; kept in memory, never in the Keychain
///   -SwiftlyFixturePlexToken <t> the Plex account's plex.tv token (default `fixture`); `plex-ok` signs in to the fixture's Seerr
///   -SwiftlySeerrReset           forget the stored Seerr session, password and per-server address of the fixture's server
///   -SwiftlyFixtureSeerrRole admin   the fixture's Seerr user becomes an administrator (`POST /__seerr/role?admin`)
///                                before the first Seerr call; default `user`
///   -SwiftlyLiveTitles a,b,c     item ids to walk through (the catalog, data-driven by the caller)
///   -SwiftlyLiveDir <path>       where the handshake files go (default: tmp)
///   -SwiftlyLiveFullscreen       macOS: also enter and leave full screen once (it crashes AppKit today, see the Mac report)
///   -SwiftlyLivePosition <s>     where the subtitle shots are taken (default 2)
///   -SwiftlyLiveLookPage         first open the subtitle look page, shoot it (`look-page`), close it; with an empty title
///                                list (`-SwiftlyLiveTitles ""`) that is the whole run
///   -SwiftlyLiveCues <file>      JSON `{"<title>": {"<stream index>": <seconds>}}`: a track whose first cue is not at the
///                                default position is shot where it HAS a cue, against its own "off@<s>" reference frame
///
/// Per title: open the player, wait for the first picture, then for "off" and for every subtitle track
/// choose it, seek to the position, pause and ask the outside for a screenshot (`shot-<n>.wanted`, answered
/// by `ack-<n>`). Everything that happened goes to `events.jsonl`. The comparison "track shown against
/// off at the same frame" is made by `Werkzeuge/live-pixel.py`.
@MainActor
enum LiveRun {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    private static func value(_ name: String) -> String? {
        arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// `-SwiftlyLiveNextAutomatic YES|NO`: the "next episode automatically" choice for this run only (never stored). Without it the
    /// device owner's own choice (stored or synced) decides, and a title's end on a device whose owner turned it off shows no
    /// card at all, which is the rule and not a failure (see `scenarioEndCard`, which reports who decided).
    static var pinnedNextAutomatic: Bool? { value("-SwiftlyLiveNextAutomatic").map { ["YES", "TRUE", "1"].contains($0.uppercased()) } }

    /// `-SwiftlyLiveDemoDevices`: the handoff box lists two made-up devices (the fixture server has none), for the `menus` scenario.
    static var demoDevices: Bool { value("-SwiftlyLiveDemoDevices") != nil }
    static let demoDeviceIDs = ["demo-wohnzimmer", "demo-schlafzimmer"]

    /// Posted before a shot: the player hides its controls so the picture and the subtitle are bare.
    nonisolated static let hideControls = Notification.Name("SwiftlyLiveHideControls")
    nonisolated static let openTracks = Notification.Name("SwiftlyLiveOpenTracks")
    /// Scenario `subtitle-search`: the tracks layer opens the search panel by itself; the panel reports its state here
    /// and presses the first row on `pickSearchRow`.
    nonisolated(unsafe) static var opensSubtitleSearch = false
    /// The player screen's card countdown clock (set by `PlayerScreen.fillSet`), so a scenario can read its value.
    nonisolated(unsafe) static var fillClockProbe: FillClock?
    /// The offering layer's countdown run (holds while a menu covers the card), set by `PlayerScreen.fillSet`.
    nonisolated(unsafe) static var countdownRunProbe: Double?
    nonisolated static let pickSearchRow = Notification.Name("SwiftlyLivePickSearchRow")
    nonisolated(unsafe) static var searchSnapshot: (phase: String, rows: [String], message: String)?
    /// tvOS: bring the controls back for the controls shot.
    nonisolated static let showControls = Notification.Name("SwiftlyLiveShowControls")
    /// iOS: a quality choice as the quality layer makes it; the object is the limit in Mbit/s (`nil` = original).
    nonisolated static let chooseQuality = Notification.Name("SwiftlyLiveChooseQuality")
    /// The live run opens a player panel for a screenshot (`menu` scenario): object "settings", "tracks" or "none".
    nonisolated static let openLayer = Notification.Name("SwiftlyLiveOpenLayer")

    /// The `filter` scenario's way to the open library page: a command posted to `LibraryView`, which fills `report`.
    nonisolated static let libraryCommand = Notification.Name("SwiftlyLiveLibraryCommand")
    @MainActor final class LibraryCommand {
        /// `open` / `close` the filter sheet, `rows` (the sheet as drawn), `pick` (a row, as the user taps it) or `titles` (the list).
        let action: String
        /// For `pick`: `years:2010-2019`, `years:none`, `language:deu`, `language:none`, `status:ungesehen`.
        let value: String
        let art: String
        var report: [String: Any]?
        init(_ action: String, value: String = "", art: String = "movies") { self.action = action; self.value = value; self.art = art }
    }
    /// Set by the `MainView` of iPhone/iPad and Mac: shows a section by its case name (`"movies"`), the way a tap on the bar does.
    static var showRegion: ((String) -> Void)?

    /// How many of the next plans the app asks for are refused (`AppModel.plan`), for the `switchfail` scenario.
    static var failPlans = 0

    /// The quality cap (Mbit/s) the timing scenario chooses mid-play (`-SwiftlyLiveQualityLimit`, default 8).
    static var qualityLimit: Int { Int(value("-SwiftlyLiveQualityLimit") ?? "") ?? 8 }

    static var an: Bool { value("-SwiftlyLiveTitles") != nil }
    static var titles: [String] { (value("-SwiftlyLiveTitles") ?? "").split(separator: ",").map(String.init) }
    /// `-SwiftlyLiveLookWatch`: per title open the player, report the look its overlay draws (`overlay` events), and keep it
    /// open until the outside creates `next-<n>` in the live folder (at most 120 s). Proves a look changed on another device
    /// reaches the open player and the next title (`Werkzeuge/look-sync-proof.py`).
    static var lookWatch: Bool { arguments.contains("-SwiftlyLiveLookWatch") }
    static var position: Double { value("-SwiftlyLivePosition").flatMap(Double.init) ?? 2 }

    /// Where a track has a cue (seconds), from `-SwiftlyLiveCues`; `nil` = the default position.
    static func cueTime(title: String, streamIndex: Int) -> Double? {
        guard let path = value("-SwiftlyLiveCues"), let data = FileManager.default.contents(atPath: path),
              let all = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return nil }
        return all[title]?[String(streamIndex)]
    }

    /// `-SwiftlyLiveMemory`: the fixture account is kept in memory only (no Keychain write, stored accounts untouched).
    nonisolated static var inMemory: Bool { ProcessInfo.processInfo.arguments.contains("-SwiftlyLiveMemory") }

    /// The session for `-SwiftlyFixture`, or `nil`.
    static func session() -> Session? {
        guard let raw = value("-SwiftlyFixture"), let address = URL(string: raw) else { return nil }
        if value("-SwiftlyFixtureKind") == "plex" {
            // `-SwiftlyFixturePlexToken`: the plex.tv token of the account (the fixture's Seerr takes `plex-ok`).
            let details = PlexSessionDetails(machineIdentifier: "plexfx", serverName: "Fixture Plex",
                                             accountToken: value("-SwiftlyFixturePlexToken") ?? "fixture", isLocal: true)
            return Session(accessToken: "fixture", userID: "demo", userName: "demo",
                           serverURL: address, kind: .plex, plex: details)
        }
        // `-SwiftlyFixtureUser gast`: the fixture's administrator mode (`--admin`) has a second user who is none.
        if value("-SwiftlyFixtureUser") == "gast" {
            return Session(accessToken: "fixture-token-gast", userID: "u2", userName: "gast", serverURL: address)
        }
        return Session(accessToken: "fixture", userID: "u1", userName: "demo", serverURL: address)
    }

    // MARK: Seerr on the fixture

    /// The Seerr connection for `-SwiftlyFixtureSeerr` (the fixture server is the Seerr as well), or `nil`.
    static func seerrAccess() -> SeerrAccess? {
        guard arguments.contains("-SwiftlyFixtureSeerr"), let raw = value("-SwiftlyFixture"),
              let address = URL(string: raw) else { return nil }
        return SeerrAccess(address: address, cookie: "connect.sid=fixture")
    }

    /// Sets the role of the fixture's Seerr user (`-SwiftlyFixtureSeerrRole admin|user`, default `user`) and waits for
    /// the answer, so the first Seerr call already sees it.
    static func seerrRole(for access: SeerrAccess) async {
        let role = value("-SwiftlyFixtureSeerrRole") == "admin" ? "admin" : "user"
        guard var parts = URLComponents(url: access.address.appendingPathComponent("__seerr/role"),
                                        resolvingAgainstBaseURL: false) else { return }
        parts.query = role
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        let answer = try? await URLSession.shared.data(for: request)
        let status = (answer?.1 as? HTTPURLResponse)?.statusCode ?? 0
        AppLog.writeOut("[Livelauf] Seerr-Rolle \(role) an \(access.address.absoluteString): \(status)")
    }

    // MARK: Handshake files

    static var dir: URL {
        if let d = value("-SwiftlyLiveDir") { return URL(fileURLWithPath: d) }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftly-live")
    }

    /// Where the run is in the matrix. One enum, so "waiting for a shot while closed" cannot exist.
    enum Phase: Equatable {
        case idle
        case opening(String)
        case playing(String)
        case selecting(String, track: String)
        case closed(String)
        case finished
    }
    private static var phase = Phase.idle { didSet { event(["phase": "\(phase)"]) } }
    private static var counter = 0

    static func event(_ fields: [String: Any]) {
        var f = fields
        f["t"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("events.jsonl")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); h.write(Data("\n".utf8)); try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: file)
        }
        AppLog.writeOut("[Livelauf] " + String(decoding: data, as: UTF8.self))
    }

    /// A free-form line for `events.jsonl` from outside this file (the tvOS player reports its focus target).
    static func note(_ fields: [String: Any]) { event(fields) }

    #if os(macOS)
    /// The window as the window server composes it (video layer included), as PNG data.
    private static func composited(_ window: NSWindow) -> Data? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    /// Asks the outside for a screenshot named `name` and waits for its answer (or 12 s).
    private static func shot(_ name: String, _ info: [String: Any]) async {
        counter += 1
        let n = counter
        var f = info
        f["name"] = name; f["n"] = n
        #if os(macOS)
        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain } ?? NSApp.windows.first
        f["windowNumber"] = window?.windowNumber ?? 0
        // The app draws its own window: `screencapture` from a script needs the Screen Recording right of the
        // calling process, which a headless run cannot be given.
        // `cacheDisplay` leaves the video layer black (it is not drawn through Core Animation's render path), so the
        // window server's own composite of the window is asked first: capturing a window of the own process needs no
        // Screen Recording right. The call is `unavailable` to Swift since macOS 15 but still exported.
        if let window, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            var png = composited(window)
            f["composited"] = png != nil
            if png == nil {
                view.cacheDisplay(in: view.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }
            if let png {
                let folder = dir.appendingPathComponent("shots", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("\(name).png")
                if (try? png.write(to: file)) != nil { f["selfShot"] = file.path }
            }
        }
        #endif
        event(f.merging(["kind": "shot-wanted"]) { a, _ in a })
        let ack = dir.appendingPathComponent("ack-\(n)")
        for _ in 0..<120 where !FileManager.default.fileExists(atPath: ack.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func current() -> VLCPlayerView? { VLCPlayerView.recent }

    private static func waitFor(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
        let steps = Int(seconds * 10)
        for _ in 0..<steps { if ok() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return ok()
    }

    // MARK: Flow

    private static var started = false
    private static var watchCount = 0

    /// Starts the walk once, as a task of its own: the `.task` of the view that calls this is cancelled as soon
    /// as the player covers it, and a cancelled task's sleeps return at once.
    static func start(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void,
                      look: ((Bool) -> Void)? = nil) {
        #if os(macOS)
        snapshotsStart()
        #endif
        guard an, !started else { return }
        started = true
        Task { @MainActor in await flow(model, open: open, close: close, look: look) }
    }

    #if os(macOS)
    private static var snapshotsRunning = false

    /// The window with its child windows on top (the hand-over stage is one), as PNG data.
    private static func snapshotWithChildren(_ window: NSWindow) -> Data? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        func image(_ w: NSWindow) -> CGImage? { capture(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0)?.takeRetainedValue() }
        guard let base = image(window), let context = CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = window.backingScaleFactor
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for child in window.childWindows ?? [] where child.isVisible {
            guard let picture = image(child) else { continue }
            let origin = CGPoint(x: (child.frame.minX - window.frame.minX) * scale, y: (child.frame.minY - window.frame.minY) * scale)
            context.draw(picture, in: CGRect(origin: origin, size: CGSize(width: picture.width, height: picture.height)))
        }
        guard let merged = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: merged).representation(using: .png, properties: [:])
    }

    /// `-SwiftlyLiveSnapshots`: every 1.5 s the window as the window server composes it goes to `<live dir>/snap/<epoch ms>.png`.
    /// A run of two clients (a hand-over) needs the Mac window at the moments in between, not only at asked-for shots.
    private static func snapshotsStart() {
        guard arguments.contains("-SwiftlyLiveSnapshots"), !snapshotsRunning else { return }
        snapshotsRunning = true
        let folder = dir.appendingPathComponent("snap", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            // The hand-over stage is built over the key window: a run that no one clicked must make its own window key.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            while !Task.isCancelled {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let png = snapshotWithChildren(window) {
                    let stamp = Int(Date().timeIntervalSince1970 * 1000)
                    try? png.write(to: folder.appendingPathComponent("\(stamp).png"))
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
    #endif

    /// `-SwiftlyLiveLookPage`: the subtitle look page on screen for a shot (the outside answers `shot-wanted` with a screenshot).
    private static func lookPage(_ look: (Bool) -> Void) async {
        phase = .opening("look-page")
        look(true)
        try? await Task.sleep(for: .seconds(3))
        await shot("look-page", ["title": "look-page", "track": "look-page"])
        look(false)
        try? await Task.sleep(for: .seconds(1))
        phase = .closed("look-page")
    }

    private static func flow(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void,
                             look: ((Bool) -> Void)?) async {
        try? await Task.sleep(for: .seconds(3))
        // Only our own files: the caller keeps its `shots` folder in the same directory.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where f == "events.jsonl" || f.hasPrefix("ack-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
        event(["kind": "start", "titles": titles, "server": value("-SwiftlyFixture") ?? "", "dir": dir.path])
        SubtitleOverlay.probe = { what, look in
            event(["kind": "overlay", "what": what, "colour": "\(look.colour)", "size": "\(look.size)"])
        }
        if arguments.contains("-SwiftlyLiveLookPage"), let look { await lookPage(look) }
        if let name = value("-SwiftlyLiveScenario") {
            await scenario(name, model, open: open, close: close)
            phase = .finished
            event(["kind": "end"])
            return
        }
        for id in titles {
            phase = .opening(id)
            let opened = Date()
            guard let item = await model.item(id: id) ?? knownItems[id], let plan = await model.plan(for: id) else {
                event(["kind": "result", "title": id, "ok": false, "why": "no item or plan"])
                continue
            }
            let resume = Double(item.userData?.playbackPositionTicks ?? 0) / 10_000_000
            let previous = current()
            open(PlayRequest(item: item, plan: plan, startAt: resume))
            // A NEW view with a picture: `recent` still points at the closed player until the next one exists.
            guard await waitFor(40, { current() !== previous && current()?.showsImage == true }), var view = current() else {
                event(["kind": "result", "title": id, "ok": false, "why": "no first picture in 40 s", "method": "\(plan.method)", "url": plan.url.absoluteString, "container": plan.container ?? "", "summary": plan.summary])
                close(); try? await Task.sleep(for: .seconds(2)); continue
            }
            phase = .playing(id)
            let firstFrame = Date().timeIntervalSince(opened)
            try? await Task.sleep(for: .seconds(1.5))
            event(["kind": "open", "title": id, "ok": true, "method": "\(plan.method)", "firstFrameSeconds": firstFrame, "resumeWanted": resume,
                   "position": view.positionSeconds, "duration": view.durationSeconds,
                   "video": "\(Int(view.videoSize.width))x\(Int(view.videoSize.height))",
                   "pipPossible": pipPossible(view),
                   // The tracks the start rule chose (the Jellyfin indices that play now, the names the panel shows), and the
                   // language the device reports: the proof of the start language rule.
                   "audioIndex": view.playingTracks.audio.map { $0 as Any } ?? NSNull(),
                   "subtitleIndex": view.playingTracks.subtitle.map { $0 as Any } ?? NSNull(),
                   "audioChosen": view.audioTracks.filter(\.isSelected).map(\.prettyName),
                   "subtitleChosen": view.subtitleTracks.filter(\.isSelected).map(\.prettyName),
                   "deviceLanguage": StartTracks.deviceLanguage ?? ""])
            if lookWatch {
                #if os(macOS)
                NSApp.activate()  // the sync polls only while the app is in front, like a user watching a title
                try? await Task.sleep(for: .seconds(1))
                event(["kind": "watch-ready", "title": id, "n": watchCount, "active": NSApp.isActive])
                #else
                event(["kind": "watch-ready", "title": id, "n": watchCount])
                #endif
                let gate = dir.appendingPathComponent("next-\(watchCount)")
                _ = await waitFor(120) { FileManager.default.fileExists(atPath: gate.path) }
                watchCount += 1
                view.stop(); close()
                let gone = await waitFor(15) { !VLCPlayerView.playersOpen }
                event(["kind": "closed", "title": id, "playersGone": gone])
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            // Resume proof: the position right after the first picture.
            if resume > 0 { await shot("\(id)--resume", ["title": id, "track": "resume", "position": view.positionSeconds]) }
            let tracks = view.subtitleTracks
            event(["kind": "tracks", "title": id, "subtitles": tracks.map { "\($0.prettyName) [\($0.stream?.index ?? -1) \($0.stream?.codec ?? "?")]" },
                   "audio": view.audioTracks.map(\.prettyName)])
            // Off first: the reference frame for the diff.
            view = await still(view, id: id, label: "off", track: nil, warmUp: true)
            view = await still(view, id: id, label: "off", track: nil)
            var offAt = Set<Double>()
            for t in tracks {
                let label = "\(t.stream?.index ?? -1)-\(t.stream?.codec ?? "x")"
                phase = .selecting(id, track: label)
                let at = cueTime(title: id, streamIndex: t.stream?.index ?? -1)
                guard let at, abs(at - position) > 0.01 else { view = await still(view, id: id, label: label, track: t); continue }
                // Its own reference frame at the cue position (subtitles off), then the track itself.
                let offLabel = "off@\(Int(at))"
                if offAt.insert(at).inserted {
                    view = await still(view, id: id, label: offLabel, track: nil, at: at, warmUp: true)
                    view = await still(view, id: id, label: offLabel, track: nil, at: at)
                }
                view = await still(view, id: id, label: label, track: t, at: at, ref: "\(id)--\(offLabel)")
            }
            if !tracks.isEmpty { view = await still(view, id: id, label: "off-again", track: nil) }
            #if os(tvOS)
            await controlsShot(view, id: id)
            #endif
            #if os(iOS)
            if id == titles.first { await pip(view) }
            #endif
            #if os(macOS)
            if id == titles.first, arguments.contains("-SwiftlyLiveFullscreen") { await fullScreen(view, id: id) }
            #endif
            view.stop()  // the player's own "done" stops the area first, then closes
            close()
            phase = .closed(id)
            let gone = await waitFor(15) { !VLCPlayerView.playersOpen }
            #if os(iOS)
            event(["kind": "closed", "title": id, "playersGone": gone, "frameStillThere": PlayerFrame.active != nil,
                   "log": gone ? [] : Array(LogRing.shared.excerpt(seconds: 30).filter { $0.contains("Rahmen") || $0.contains("Player") || $0.contains("Schlie") }.suffix(12))])
            #else
            event(["kind": "closed", "title": id, "playersGone": gone])
            #endif
            try? await Task.sleep(for: .seconds(1))
        }
        phase = .finished
        event(["kind": "end"])
    }

    private static func pipPossible(_ view: VLCPlayerView) -> Bool {
        #if os(iOS)
        return view.avEngine?.pipPossible ?? false
        #else
        return false
        #endif
    }

    /// Chooses a track (or off), parks on the position and asks for a shot.
    @discardableResult
    private static func still(_ shown: VLCPlayerView, id: String, label: String, track: SurfaceTrack?, at: Double? = nil,
                              ref: String? = nil, warmUp: Bool = false) async -> VLCPlayerView {
        var view = shown
        var cueWait = 0.0
        // A pick on a transcoded stream (a picture subtitle burned in, or taken out again) reloads the title: the screen asks
        // for a new plan and loads the new stream into a new engine (maybe a new player view). Carry on only once that
        // picture is up, otherwise the seek and the shot hit the stopped stream.
        let engineBefore = view.avEngine.map { ObjectIdentifier($0 as AnyObject) }
        let viewBefore = view
        view.selectSubtitle(track)
        let reloading = await waitFor(track?.stream?.codec == "hdmv_pgs_subtitle" || track == nil ? 8 : 2) {
            current() !== viewBefore || current()?.avEngine.map { ObjectIdentifier($0 as AnyObject) } != engineBefore
        }
        if reloading {
            let ready = await waitFor(40) {
                guard let now = current(), now.showsImage else { return false }
                return now.avEngine.map { ObjectIdentifier($0 as AnyObject) } != engineBefore || now !== viewBefore
            }
            if let next = current() { view = next }
            event(["kind": "reloaded", "title": id, "track": label, "ready": ready])
        }
        let wanted = track?.stream?.index ?? -1
        let took = await waitFor(5) { (view.playingTracks.subtitle ?? -1) == wanted }
        view.pause()
        let jump = abs(view.positionSeconds - (at ?? position))
        view.seek(toSeconds: at ?? position)
        // A far backward seek of a paused player shows the new picture late (a stale reference frame gave a false green on tvOS).
        try? await Task.sleep(for: .seconds(jump > 30 ? 3.5 : 1.0))
        NotificationCenter.default.post(name: hideControls, object: nil)
        try? await Task.sleep(for: .seconds(0.8))
        // A picture subtitle has no cue list: on a transcode the server burns it into the picture (engine track stays -1).
        let bitmap = ["pgs", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"].contains(track?.stream?.codec ?? "")
        if !bitmap && track != nil {
            // A text track fills its cue list after it is chosen (an embedded one while the demuxer reads on after the seek, a
            // subtitle file the server delivers during a transcode while the engine decodes it): wait for it (up to 6 s).
            let began = Date()
            let settled = await waitFor(6) { ((view.avEngine as? CorePlaybackBackend)?.liveSubtitleState?["cues"] as? Int ?? 0) > 0 }
            cueWait = Date().timeIntervalSince(began)
            if !settled { event(["kind": "note", "title": id, "note": "no cue within 6 s after the seek: \(label)"]) }
        }
        if warmUp { return view }  // the first seek of a paused player lands a frame late: this pass only primes it
        var info: [String: Any] = ["cueWait": cueWait, "title": id, "track": label, "position": view.positionSeconds,
                                   "chosen": took, "playing": view.isPlaying]
        if let ref { info["ref"] = ref }
        if let state = (view.avEngine as? CorePlaybackBackend)?.liveSubtitleState { info["engine"] = state }
        await shot("\(id)--\(label)", info)
        _ = view.resume()
        return view
    }

    #if os(iOS)
    private static func pip(_ view: VLCPlayerView) async {
        guard view.avEngine?.pipPossible == true else { event(["kind": "pip", "started": false, "why": "not possible"]); return }
        var started = false
        view.onPiPStateChanged = { started = $0 }
        view.startPiP()
        let ok = await waitFor(6) { started }
        event(["kind": "pip", "started": ok])
        if ok { await shot("pip", ["title": "pip", "track": "pip"]); view.stopPiP(); try? await Task.sleep(for: .seconds(1)) }
    }
    #endif

    #if os(tvOS)
    /// The controls on top of the picture (the focus target arrives as `focus` events from the player).
    private static func controlsShot(_ view: VLCPlayerView, id: String) async {
        view.pause()
        NotificationCenter.default.post(name: showControls, object: nil)
        try? await Task.sleep(for: .seconds(1.2))
        await shot("\(id)--controls", ["title": id, "track": "controls", "position": view.positionSeconds])
        _ = view.resume()
    }
    #endif

    #if os(macOS)
    private static func fullScreen(_ view: VLCPlayerView, id: String) async {
        guard let window = view.window ?? NSApp.windows.first(where: { $0.isVisible }) else {
            event(["kind": "fullscreen", "ok": false, "why": "no window"]); return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.5))
        // Every path a user has, each entered and left once with the player open. A key goes through the window's
        // own key handling (`sendEvent`, no Accessibility right needed), the green button is clicked as a button.
        func key(_ chars: String, code: UInt16) {
            for down in [true, false] {
                guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: code) else { continue }
                NSApp.sendEvent(e)
            }
        }
        func green() {
            let button = window.standardWindowButton(.zoomButton)
            event(["kind": "fullscreen-green", "button": button != nil, "enabled": button?.isEnabled ?? false,
                   "canFullScreen": window.collectionBehavior.contains(.fullScreenPrimary),
                   "frame": NSStringFromRect(window.frame), "zoomed": window.isZoomed])
            // A disabled button cannot be clicked (what a user would see); then the button's own action is sent, which
            // is the same `toggleFullScreen:` / `zoom:` the system runs, so the notifications still get exercised.
            if button?.isEnabled == true { button?.performClick(nil) }
            else if let button, let action = button.action { NSApp.sendAction(action, to: button.target, from: button) }
        }
        let paths: [(name: String, enter: () -> Void, leave: () -> Void)] = [
            ("toggle", { window.toggleFullScreen(nil) }, { window.toggleFullScreen(nil) }),
            ("key F, key Esc", { key("f", code: 3) }, { key("\u{1b}", code: 53) }),
            ("green button", green, green),
            ("key F, key F", { key("f", code: 3) }, { key("f", code: 3) }),
        ]
        for path in paths {
            let was = window.styleMask.contains(.fullScreen)
            path.enter()
            let entered = await waitFor(8) { window.styleMask.contains(.fullScreen) != was }
            try? await Task.sleep(for: .seconds(1.5))
            if path.name == "toggle" {
                await shot("\(id)--fullscreen", ["title": id, "track": "fullscreen", "windowNumber": window.windowNumber])
            }
            path.leave()
            let left = await waitFor(8) { !window.styleMask.contains(.fullScreen) }
            try? await Task.sleep(for: .seconds(1))
            event(["kind": "fullscreen", "path": path.name, "ok": left && entered, "entered": entered, "left": left,
                   "mask": window.styleMask.rawValue, "main": window.isMainWindow, "active": NSApp.isActive,
                   "playing": view.isPlaying, "zoomed": window.isZoomed, "frame": NSStringFromRect(window.frame)])
            if !left { window.toggleFullScreen(nil); _ = await waitFor(8) { !window.styleMask.contains(.fullScreen) } }
        }
    }
    #endif
}
// MARK: Scenarios (`-SwiftlyLiveScenario <name>`): one behaviour per run, driven like a user would, judged from the events

extension LiveRun {
    private static var gateCount = 0

    /// Opens `id` through the screen (the real start rule picks the tracks) and waits for the first picture.
    /// Titles read from the server before it was cut (offline the screen has its own copy of the title).
    private static var knownItems: [String: Item] = [:]

    private static func openTitle(_ model: AppModel, _ id: String, open: @escaping (PlayRequest) -> Void) async -> VLCPlayerView? {
        phase = .opening(id)
        guard let item = await model.item(id: id) ?? knownItems[id], let plan = await model.plan(for: id) else {
            event(["kind": "result", "title": id, "ok": false, "why": "no item or plan"]); return nil
        }
        let previous = current()
        open(PlayRequest(item: item, plan: plan, startAt: Double(item.userData?.playbackPositionTicks ?? 0) / 10_000_000))
        guard await waitFor(40, { current() !== previous && current()?.showsImage == true }), let view = current() else {
            event(["kind": "result", "title": id, "ok": false, "why": "no first picture in 40 s", "method": "\(plan.method)"]); return nil
        }
        phase = .playing(id)
        try? await Task.sleep(for: .seconds(1.5))
        return view
    }

    private static func closeTitle(_ view: VLCPlayerView, _ id: String, close: () -> Void) async {
        view.stop(); close(); phase = .closed(id)
        _ = await waitFor(15) { !VLCPlayerView.playersOpen }
        try? await Task.sleep(for: .seconds(1))
    }

    private static func listing(_ view: VLCPlayerView, _ id: String, _ step: String) {
        let tracks = view.subtitleTracks
        let names = tracks.map { "\($0.prettyName) [\($0.stream?.index ?? -1) \($0.stream?.codec ?? "?") forced=\($0.stream?.isForced == true)]" }
        event(["kind": "tracks", "step": step, "title": id, "subtitles": names, "distinct": Set(names).count == names.count,
               "playing": view.playingTracks.subtitle ?? -1])
    }

    /// Pause at `at`, wait for the picture and the cue, hide the controls and shoot; then play on.
    private static func park(_ view: VLCPlayerView, _ id: String, name: String, at: Double, wait: Double = 5) async {
        view.pause()
        let jump = abs(view.positionSeconds - at)
        view.seek(toSeconds: at)
        try? await Task.sleep(for: .seconds(jump > 30 ? 3.5 : 1.0))
        NotificationCenter.default.post(name: hideControls, object: nil)
        try? await Task.sleep(for: .seconds(0.8))
        if view.playingTracks.subtitle ?? -1 >= 0 {
            _ = await waitFor(wait) { ((view.avEngine as? CorePlaybackBackend)?.liveSubtitleState?["cues"] as? Int ?? 0) > 0 }
        }
        var info: [String: Any] = ["title": id, "track": name, "position": view.positionSeconds, "playing": view.isPlaying,
                                   "subtitle": view.playingTracks.subtitle ?? -1]
        if let state = (view.avEngine as? CorePlaybackBackend)?.liveSubtitleState { info["engine"] = state }
        await shot("\(id)--\(name)", info)
        _ = view.resume()
    }

    private static func textTrack(_ view: VLCPlayerView) -> SurfaceTrack? {
        view.subtitleTracks.first { ["subrip", "srt", "mov_text", "ass", "ssa"].contains($0.stream?.codec ?? "") }
    }

    private static func scenario(_ name: String, _ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        switch name {
        case "filestyle": await scenarioFileStyle(model, open: open, close: close)
        case "start": await scenarioStart(model, open: open, close: close)
        case "memory": await scenarioMemory(model, open: open, close: close)
        case "download": await scenarioDownload(model, open: open, close: close)
        case "timing": await scenarioTiming(model, open: open, close: close)
        case "menu": await scenarioMenu(model, open: open, close: close)
        case "menus": await scenarioMenus(model, open: open, close: close)
        case "skipintro": await scenarioSkipIntro(model, open: open, close: close)
        case "menu-motion": await scenarioMenuMotion(model, open: open, close: close)
        case "player-bar": await scenarioPlayerBar(model, open: open, close: close)
        case "chapters": await scenarioChapters(model, open: open, close: close)
        case "chapters-remote": await scenarioChaptersRemote(model, open: open, close: close)
        case "pausedseek": await scenarioPausedSeek(model, open: open, close: close)
        case "chain": await scenarioChain(model, open: open, close: close)
        case "soak": await scenarioSoak(model, open: open, close: close)
        case "exit": await scenarioExit(model, open: open, close: close)
        case "firstframe": await scenarioFirstFrame(model, open: open, close: close)
        case "background": await scenarioBackground(model, open: open, close: close)
        case "inactive": await scenarioInactive(model, open: open, close: close)
        case "progress": await scenarioProgress(model, open: open, close: close)
        case "language": await scenarioLanguage(model, open: open, close: close)
        case "switchfail": await scenarioSwitchFail(model, open: open, close: close)
        case "endcard": await scenarioEndCard(model, open: open, close: close)
        case "endseek": await scenarioEndCard(model, open: open, close: close, seekToEnd: true)
        case "menus-countdown": await scenarioMenusCountdown(model, open: open, close: close)
        case "filter": await scenarioFilter()
        case "tabs": await scenarioTabs(model)
        case "subtitle-search": await scenarioSubtitleSearch(model, open: open, close: close)
        default: event(["kind": "result", "ok": false, "why": "unknown scenario \(name)"])
        }
    }

    /// Sends a command to the library page and waits for its report (12 s).
    private static func ask(_ action: String, _ value: String = "") async -> [String: Any] {
        let command = LibraryCommand(action, value: value)
        NotificationCenter.default.post(name: libraryCommand, object: command)
        for _ in 0..<120 where command.report == nil { try? await Task.sleep(for: .milliseconds(100)) }
        return command.report ?? ["error": "no answer"]
    }

    /// The list once it has settled: loaded, not growing for 1.5 s.
    private static func settledTitles() async -> [String: Any] {
        var last: [String: Any] = [:]
        var stable = 0
        for _ in 0..<150 {
            try? await Task.sleep(for: .milliseconds(500))
            let now = await ask("titles")
            let key = "\(now["loads"] ?? "")|\(now["identifier"] ?? "")|\((now["ids"] as? [String])?.count ?? -1)"
            let before = "\(last["loads"] ?? "")|\(last["identifier"] ?? "")|\((last["ids"] as? [String])?.count ?? -1)"
            stable = key == before ? stable + 1 : 0
            last = now
            if stable >= 3, (now["loads"] as? Bool) == false { break }
        }
        return last
    }

    /// Waits (20 s) until the open sheet holds more than the four status rows and nothing loads any more: the core adds the year and
    /// language groups after the sheet opened.
    private static func sheetLoaded() async {
        for _ in 0..<80 {
            let rows = await ask("rows")
            if (rows["loading"] as? Bool) == false, ((rows["rows"] as? [String])?.count ?? 0) > 4 { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// The library filter sheet (GitHub #28): open the movies library, pick the decade 2010-2019, then German, then "unwatched" on top,
    /// and say after each step which titles the list holds (`Werkzeuge/live-filter-judge.py` checks them against the fixture's rule).
    /// The fixture runs with `SWIFTLY_FIXTURE_FILTER_SET=1` (three decades, audio languages, every fourth film watched).
    /// Subtitle search on the running player: German search -> three rows -> press the first -> the server's new track is
    /// in the subtitle list after the reload. Shots: the result rows, the track list afterwards.
    private static func scenarioSubtitleSearch(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        guard let view = await openTitle(model, "g1", open: open) else { return }
        try? await Task.sleep(for: .seconds(3))
        let before = Array(view.subtitleNames().values).sorted()
        event(["kind": "subtitle-before", "tracks": before])
        opensSubtitleSearch = true
        NotificationCenter.default.post(name: openTracks, object: nil)
        for _ in 0..<40 where searchSnapshot?.phase != "results" { try? await Task.sleep(for: .milliseconds(500)) }
        event(["kind": "subtitle-search", "phase": searchSnapshot?.phase ?? "none", "rows": searchSnapshot?.rows ?? []])
        try? await Task.sleep(for: .milliseconds(800))
        await shot("search-results", [:])
        NotificationCenter.default.post(name: pickSearchRow, object: nil)
        for _ in 0..<60 where searchSnapshot?.phase != "done" { try? await Task.sleep(for: .milliseconds(500)) }
        event(["kind": "subtitle-done", "phase": searchSnapshot?.phase ?? "none", "message": searchSnapshot?.message ?? ""])
        try? await Task.sleep(for: .seconds(7))
        let names = Array(view.subtitleNames().values).sorted()
        // The player names a track by language, format and source, so the fixture's "Deutsch (Suche)" shows as "Deutsch · SRT · Datei":
        // the new track is the one that was not in the list before.
        let added = names.filter { !before.contains($0) }
        let chosen = view.subtitleTracks.filter(\.isSelected).map(\.prettyName)
        event(["kind": "subtitle-after", "tracks": names, "found": !added.isEmpty, "added": added, "chosen": chosen])
        opensSubtitleSearch = false
        NotificationCenter.default.post(name: openTracks, object: nil)
        try? await Task.sleep(for: .seconds(1.5))
        await shot("tracks-after", [:])
        // The result holds only when the new track is also the one that is switched on after the reload.
        event(["kind": "result", "ok": !added.isEmpty && chosen.contains { added.contains($0) }])
    }

    private static func scenarioFilter() async {
        showRegion?("movies")
        try? await Task.sleep(for: .seconds(2))
        func step(_ name: String, _ pick: String?) async {
            if let pick {
                _ = await ask("open")
                await sheetLoaded()
                var picked = await ask("pick", pick)
                for _ in 0..<20 where (picked["found"] as? Bool) != true {
                    try? await Task.sleep(for: .milliseconds(500))
                    picked = await ask("pick", pick)
                }
                event(["kind": "filter-pick", "step": name, "pick": pick, "found": picked["found"] ?? false])
                try? await Task.sleep(for: .milliseconds(600))
            }
            let list = await settledTitles()
            event(["kind": "filter-list", "step": name, "pill": list["pill"] ?? "", "identifier": list["identifier"] ?? "",
                   "total": list["total"] ?? -1, "ids": list["ids"] ?? [], "years": list["years"] ?? []])
        }
        await step("all", nil)
        await step("decade", "years:2010-2019")
        await step("decade+german", "language:deu")
        await step("decade+german+unwatched", "status:ungesehen")
        // The sheet as the user sees it with the three choices on: the one shot.
        _ = await ask("open")
        await sheetLoaded()
        let rows = await ask("rows")
        event(["kind": "filter-sheet", "rows": rows["rows"] ?? [], "loading": rows["loading"] ?? true])
        try? await Task.sleep(for: .seconds(1))
        await shot("filter-sheet", ["step": "decade+german+unwatched"])
        _ = await ask("close")
    }

    /// `-SwiftlyLiveScenario tabs`: each bottom-bar tab selected once (Start, Filme, Serien, Downloads, Suche), one shot each
    /// (`tab-<region>`), so the outline/filled state of the five icons can be judged. The Downloads tab is shown for the run only.
    private static func scenarioTabs(_ model: AppModel) async {
        let before = model.downloadsAn
        model.downloadsAn = true
        try? await Task.sleep(for: .seconds(2))
        for region in ["start", "movies", "seriesList", "downloads", "search"] {
            showRegion?(region)
            try? await Task.sleep(for: .seconds(1.5))
            await shot("tab-\(region)", ["region": region])
        }
        model.downloadsAn = before
        event(["kind": "result", "ok": true])
    }

    /// The picture after a seek while PAUSED must be the frame at the target (the burned-in clock of the bench clips shows it).
    /// Shots at several times after the seek, backward and forward, and a control that seeks while playing and pauses afterwards;
    /// `Werkzeuge/live-pausedseek-judge.py` reads the clock of each shot.
    private static func scenarioPausedSeek(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-multi-mkv"
        guard let view = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        func look(_ name: String, _ target: Double, _ after: Double) async {
            try? await Task.sleep(for: .seconds(after))
            await shot("\(id)--\(name)", ["title": id, "track": name, "position": view.positionSeconds, "playing": view.isPlaying, "target": target])
        }
        // Play on to about 6 s, pause, seek back to 2.5: shots at 0.4 s, 1.5 s and 3 s.
        _ = await waitFor(12) { view.positionSeconds >= 6 }
        view.pause()
        view.seek(toSeconds: 2.5)
        await look("back-0.4s", 2.5, 0.4)
        await look("back-1.5s", 2.5, 1.1)
        await look("back-3s", 2.5, 1.5)
        // A second paused seek, forward to 8.0.
        view.seek(toSeconds: 8.0)
        await look("fwd-1.5s", 8.0, 1.5)
        // Scrubbing while paused: quick seeks in a row; only the last frame counts and no play may stack up.
        view.seek(toSeconds: 1.0)
        view.seek(toSeconds: 4.0)
        view.seek(toSeconds: 5.5)
        await look("rapid-1.5s", 5.5, 1.5)
        // Control: seek while playing, pause after the landing.
        _ = view.resume()
        view.seek(toSeconds: 2.5)
        try? await Task.sleep(for: .seconds(0.6))
        view.pause()
        await look("ctl-play-seek-pause", 2.5, 1.0)
        event(["kind": "engine-log", "lines": Array(LogRing.shared.excerpt(seconds: 90).filter { $0.contains("[Aether") }.suffix(60))])
        await closeTitle(view, id, close: close)
    }

    /// Back-to-back subtitle cues (`bm-chain`, cues at 1-2 s, 2-3 s, 3.2-4.2 s, 4.6-5.6 s and 7-8 s): plays the title through with the
    /// text track on and writes every subtitle refresh (media time, line on screen, wall clock) to `chain-frames.jsonl`. The outside
    /// (`Werkzeuge/live-lauf.py --scenario chain`) records the screen and judges it with `Werkzeuge/chain-judge.py`.
    private static func scenarioChain(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-chain"
        guard let view = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        view.pause()
        view.selectSubtitle(textTrack(view))
        _ = await waitFor(5) { ((view.avEngine as? CorePlaybackBackend)?.liveSubtitleState?["cues"] as? Int ?? 0) > 0 }
        view.seek(toSeconds: 0)
        try? await Task.sleep(for: .seconds(1))
        let log = dir.appendingPathComponent("chain-frames.jsonl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: log)
        AetherPlayerEngine.subtitleProbe = { media, line in
            let row: [String: Any] = ["media": (media * 1000).rounded() / 1000, "wall": Date().timeIntervalSince1970, "line": line ?? ""]
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                  let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile(); h.write(data); h.write(Data("\n".utf8)); try? h.close()
        }
        event(["kind": "chain-go", "position": view.positionSeconds, "track": view.playingTracks.subtitle ?? -1])
        _ = view.resume()
        _ = await waitFor(14) { view.positionSeconds >= 9.2 }
        AetherPlayerEngine.subtitleProbe = nil
        event(["kind": "chain-done", "position": view.positionSeconds])
        await closeTitle(view, id, close: close)
    }

    /// Progress reports: play a long title for `-SwiftlyLiveSeconds` (default 45 s), pause 3 s, play on, seek, and close. The
    /// outside (`Werkzeuge/live-lauf.py --scenario progress`) reads what the fixture server received (`/fixture/reportlog`: path,
    /// time and position of every report) and checks the spacing.
    private static func scenarioProgress(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-pgs-mkv"
        guard let view = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        let seconds = Double(value("-SwiftlyLiveSeconds") ?? "") ?? 45
        event(["kind": "progress-play", "position": view.positionSeconds, "seconds": seconds])
        try? await Task.sleep(for: .seconds(seconds))
        event(["kind": "progress-pause", "position": view.positionSeconds])
        view.pause()
        try? await Task.sleep(for: .seconds(3))
        _ = view.resume()
        try? await Task.sleep(for: .seconds(4))
        view.seek(toSeconds: max(0, view.positionSeconds - 30))
        try? await Task.sleep(for: .seconds(3))
        event(["kind": "progress-close", "position": view.positionSeconds])
        await closeTitle(view, id, close: close)
    }

    /// The end of an episode no outro reaches the end of (`bm-ep1` of the `swiftly-live-media-b6a` fixture: 330 s, resumed at 315 s, no
    /// marker, a next episode; the server runs with `SWIFTLY_FIXTURE_NO_MARKERS=1`): the core's card must open with the last seven seconds
    /// (not 30 s before the end), fill, and the next episode must start. Samples every 250 ms: position, left to the end, the core's offer.
    private static func scenarioEndCard(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void,
                                        seekToEnd: Bool = false) async {
        let id = titles.first ?? "bm-ep1"
        guard let first = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        let engine = ObjectIdentifier(first.avEngine as AnyObject)
        // Who decides "next episode automatically" on this device: a hidden offer with it off is the rule, not a failure.
        let stored = UserDefaults.standard.object(forKey: "naechsteAuto") as? Bool
        let effective = pinnedNextAutomatic ?? model.nextAutomatic
        event(["kind": "endcard-prefs", "nextAutomatic": effective, "pinned": pinnedNextAutomatic.map { $0 as Any } ?? NSNull(),
               "storedChoice": stored.map { $0 as Any } ?? NSNull(), "accountChoice": model.nextAutomaticAccount.map { $0 as Any } ?? NSNull()])
        let began = Date()
        var cardAt: Double?, leftAtCard: Double?, shotCard = false, switchedAt: Double?
        var samples: [[String: Any]] = []
        var sought = false
        for _ in 0..<(seekToEnd ? 1000 : 200) {
            try? await Task.sleep(for: .milliseconds(seekToEnd ? 50 : 250))
            guard let now = current() else { continue }
            let t = (Date().timeIntervalSince(began) * 100).rounded() / 100
            let same = ObjectIdentifier(now.avEngine as AnyObject) == engine
            // `endseek`: once the episode plays, jump to the last 0.02 s, past the card's window, so the end of the file comes with no card.
            if seekToEnd, !sought, same, now.isPlaying, now.durationSeconds > 20, now.positionSeconds > 3 {
                sought = true
                event(["kind": "endseek", "from": now.positionSeconds, "to": now.durationSeconds - 0.02])
                now.seek(toSeconds: now.durationSeconds - 0.02)
            }
            let offer = (now.avEngine as? CorePlaybackBackend)?.offerNow
            var kind = "none", share = -1.0
            if let offer {
                switch offer {
                case .hidden: kind = "hidden"
                case .button: kind = "button"
                case let .card(_, s, _): kind = "card"; share = s
                }
            }
            let read = now.coreTransport?.value
            let position = read?.position ?? now.positionSeconds, duration = read?.duration ?? now.durationSeconds
            samples.append(["t": t, "position": (position * 10).rounded() / 10, "left": ((duration - position) * 10).rounded() / 10, "offer": kind,
                            "share": (share * 100).rounded() / 100, "sameEngine": same])
            if kind == "card", cardAt == nil { cardAt = t; leftAtCard = duration - position }
            if kind == "card", !shotCard, let c = cardAt, t - c >= 3 {
                shotCard = true
                await shot("\(id)--card", ["title": id, "track": "card", "position": position, "playing": now.isPlaying])
            }
            if !same, switchedAt == nil {
                switchedAt = t
                try? await Task.sleep(for: .seconds(3))
                if let next = current() { await shot("\(id)--next-episode", ["title": id, "track": "next", "position": next.positionSeconds, "playing": next.isPlaying]) }
                break
            }
        }
        event(["kind": "endcard", "nextAutomatic": effective, "samples": samples, "cardAt": cardAt ?? -1, "leftAtCard": leftAtCard ?? -1, "switchedAt": switchedAt ?? -1,
               "seconds": (Date().timeIntervalSince(began) * 10).rounded() / 10])
        await closeTitle(current() ?? first, id, close: close)
    }

    /// A switch the core asked for finds no plan (a quality choice mid-play; `failPlans` refuses it, which is what a failing
    /// next-episode plan looks like to the screen): the old title must keep its place and play on, the core's hint must show for
    /// about 3 s, and the same choice made again must work. Samples every 250 ms: hint, position, running.
    private static func scenarioSwitchFail(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-pgs-mkv"
        guard var view = await openTitle(model, id, open: open) else { return }
        // The controls stay up (the iPhone draws the hint inside them): the failure comes right after the first picture.
        let before = view.positionSeconds
        event(["kind": "switchfail", "phase": "before", "position": before, "playing": view.isPlaying])
        failPlans = 1
        let began = Date()
        NotificationCenter.default.post(name: chooseQuality, object: qualityLimit)
        var hintSince: Double?, hintGone: Double?, shotHint = false
        var samples: [[String: Any]] = []
        for _ in 0..<28 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let now = current() else { continue }
            let t = Date().timeIntervalSince(began)
            let read = now.coreTransport?.value
            let hint = read?.hint
            samples.append(["t": (t * 100).rounded() / 100, "hint": hint ?? "", "position": read?.position ?? now.positionSeconds,
                            "running": read?.running ?? now.isPlaying, "engineRunning": now.isPlaying])
            if hint != nil, hintSince == nil { hintSince = t }
            if hint == nil, hintSince != nil, hintGone == nil { hintGone = t }
            if hint != nil, !shotHint {
                shotHint = true
                await shot("\(id)--2-hint", ["title": id, "track": "hint", "position": now.positionSeconds, "playing": now.isPlaying])
            }
        }
        view = current() ?? view
        let after = view.positionSeconds
        let kept = after >= before - 1 && view.isPlaying
        event(["kind": "switchfail", "phase": "samples", "samples": samples])
        event(["kind": "switchfail", "phase": "after-failure", "before": before, "position": after, "playing": view.isPlaying,
               "hintSeconds": (hintSince != nil && hintGone != nil) ? (hintGone! - hintSince!) : -1,
               "hintFirstAt": hintSince ?? -1, "keptItsPlace": kept])
        await shot("\(id)--3-after-hint", ["title": id, "track": "after-hint", "position": after, "playing": view.isPlaying])
        // The retry: the same kind of choice again (another limit, so the core sees a change). Now the plan comes.
        let engineBefore = view.avEngine.map { ObjectIdentifier($0 as AnyObject) }
        let viewBefore = view
        NotificationCenter.default.post(name: chooseQuality, object: qualityLimit / 2)
        let reloaded = await waitFor(25) {
            guard let now = current(), now.showsImage else { return false }
            return now !== viewBefore || now.avEngine.map({ ObjectIdentifier($0 as AnyObject) }) != engineBefore
        }
        view = current() ?? view
        try? await Task.sleep(for: .seconds(2))
        event(["kind": "switchfail", "phase": "retry", "reloaded": reloaded, "position": view.positionSeconds, "playing": view.isPlaying])
        await shot("\(id)--4-retry", ["title": id, "track": "retry", "position": view.positionSeconds, "playing": view.isPlaying])
        let ok = kept && reloaded && hintSince != nil
        event(["kind": "result", "title": id, "ok": ok,
               "why": ok ? "old title kept its place, hint shown, retry reloaded" : "kept=\(kept) hint=\(hintSince != nil) retry=\(reloaded)"])
        await closeTitle(view, id, close: close)
    }

    /// Pause, send the app to the background (the outside launches another app: `background-wanted`), wait there for the
    /// `-SwiftlyLiveBackgroundSeconds` (default 60), come back (`foreground-wanted` is answered by the outside launching
    /// the app again), press Play and measure how long until the picture runs again. Events: engine state and position
    /// before, after the return and after Play, the time to the first running frame, a shot after the return and after Play.
    private static func scenarioBackground(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-pgs-mkv"
        guard let view = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        _ = await waitFor(20) { view.positionSeconds >= 5 }
        view.pause()
        try? await Task.sleep(for: .seconds(1))
        let before = view.positionSeconds
        event(["kind": "bg-before", "position": before, "playing": view.isPlaying])
        #if canImport(UIKit)
        event(["kind": "background-wanted"])
        _ = await waitFor(60) { UIApplication.shared.applicationState == .background }
        let began = Date()
        event(["kind": "bg-entered", "state": "\(UIApplication.shared.applicationState.rawValue)"])
        // Back to the front: the outside launches the app again after the wanted time.
        _ = await waitFor(Double(value("-SwiftlyLiveBackgroundSeconds") ?? "") ?? 60 + 120) { UIApplication.shared.applicationState == .active }
        let away = Date().timeIntervalSince(began)
        // `-SwiftlyLiveBgPlayAtOnce`: Play is pressed the moment the app is active again, while the picture rebuild still runs
        // (the press that used to be lost), not after the rebuild had two seconds to finish.
        let atOnce = ProcessInfo.processInfo.arguments.contains("-SwiftlyLiveBgPlayAtOnce")
        if !atOnce { try? await Task.sleep(for: .seconds(2)) }
        event(["kind": "bg-returned", "away": away, "position": view.positionSeconds, "playing": view.isPlaying, "playAtOnce": atOnce])
        if !atOnce { await shot("\(id)--after-return", ["title": id, "track": "after-return", "position": view.positionSeconds, "playing": view.isPlaying]) }
        // `-SwiftlyLiveBgDeadProducer[=silent]`: the title was paused (Picture in Picture on a device), the long background is over
        // and the engine's local producer is gone (forced here: the simulator never closes it). `silent`: nothing rebuilt on the
        // return, so the Play press itself must rebuild; otherwise the failure arrives as an engine error and rebuilds once on its own.
        #if DEBUG && os(iOS)
        if let dead = value("-SwiftlyLiveBgDeadProducer") {
            view.debugForceProducerTeardown(silent: dead == "silent")
            try? await Task.sleep(for: .seconds(4))
            event(["kind": "bg-dead", "silent": dead == "silent", "position": view.positionSeconds, "playing": view.isPlaying])
        }
        #endif
        let pressed = Date()
        _ = view.resume()
        let ran = await waitFor(20) { view.isPlaying && view.positionSeconds > before + 0.5 }
        event(["kind": "bg-play", "ran": ran, "msToPlay": Int(Date().timeIntervalSince(pressed) * 1000),
               "position": view.positionSeconds, "before": before])
        try? await Task.sleep(for: .seconds(2))
        await shot("\(id)--after-play", ["title": id, "track": "after-play", "position": view.positionSeconds, "playing": view.isPlaying])
        event(["kind": "engine-log", "lines": Array(LogRing.shared.excerpt(seconds: 600).filter { $0.contains("[Lebenslage]") || $0.contains("#597") || $0.contains("grace") || $0.contains("[Melden]") }.suffix(80))])
        event(["kind": "result", "title": id, "ok": ran, "why": ran ? "picture and play came back" : "play did nothing after \(Int(away)) s in the background"])
        #endif
        await closeTitle(view, id, close: close)
    }

    /// Notification Center and Control Center pulled down while the film PLAYS. Phase 1: the app is only inactive (the
    /// notifications `willResignActive`, `didBecomeActive` are posted, nothing else). Phase 2: the app really goes to the
    /// background (the outside launches another app, `background-wanted`) and comes back after `-SwiftlyLiveBackgroundSeconds`.
    /// Nothing presses Play. Events per phase: playing, position moved, and how many picture rebuilds ran (`Bild zurück:`).
    /// Expected: playing and moving after both phases, no rebuild in either.
    private static func scenarioInactive(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-pgs-mkv"
        guard let view = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        _ = await waitFor(20) { view.positionSeconds >= 5 && view.isPlaying }
        #if canImport(UIKit)
        func rebuilds() -> Int { LogRing.shared.excerpt(seconds: 3600).filter { $0.contains("Bild zurück:") }.count }
        func snap(_ phase: String, _ extra: [String: Any] = [:]) async {
            let p0 = view.positionSeconds
            try? await Task.sleep(for: .seconds(3))
            var e: [String: Any] = ["kind": "inactive-\(phase)", "playing": view.isPlaying, "moved": view.positionSeconds > p0 + 1,
                                    "position": view.positionSeconds, "rebuilds": rebuilds(),
                                    "appState": "\(UIApplication.shared.applicationState.rawValue)"]
            for (k, v) in extra { e[k] = v }
            event(e)
        }
        await snap("start")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        await snap("resigned")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await snap("active-again")
        let afterInactive = view.isPlaying && rebuilds() == 0
        event(["kind": "background-wanted"])
        _ = await waitFor(60) { UIApplication.shared.applicationState == .background }
        try? await Task.sleep(for: .seconds(1.5))
        event(["kind": "bg-entered", "playing": view.isPlaying, "position": view.positionSeconds])
        _ = await waitFor(Double(value("-SwiftlyLiveBackgroundSeconds") ?? "") ?? 60 + 120) { UIApplication.shared.applicationState == .active }
        await snap("background-return")
        let afterBackground = view.isPlaying
        event(["kind": "engine-log", "lines": Array(LogRing.shared.excerpt(seconds: 600).filter {
            $0.contains("[Lebenslage]") || $0.contains("AppBackgrounded") || $0.contains("rate change") || $0.contains("#597") || $0.contains("grace")
        }.suffix(60))])
        event(["kind": "result", "title": id, "ok": afterInactive && afterBackground,
               "why": "inactive only: playing=\(afterInactive) · after background: playing=\(afterBackground)"])
        #endif
        await closeTitle(view, id, close: close)
    }

    /// Line 3: the ASS track of `bm-ass-styled` with "keep the file's style" on (file colours) and off (our look).
    private static func scenarioFileStyle(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-ass-styled"
        for keep in [true, false] {
            model.subtitleLook.keepFileStyle = keep
            event(["kind": "look", "keepFileStyle": keep])
            guard let view = await openTitle(model, id, open: open) else { continue }
            listing(view, id, "keep=\(keep)")
            let ass = view.subtitleTracks.first { ["ass", "ssa"].contains($0.stream?.codec ?? "") } ?? view.subtitleTracks.first
            view.selectSubtitle(ass)
            _ = await waitFor(5) { (view.playingTracks.subtitle ?? -1) == (ass?.stream?.index ?? -2) }
            await park(view, id, name: keep ? "keep-on" : "keep-off", at: 2.0)
            view.selectSubtitle(nil)
            await park(view, id, name: keep ? "off-on" : "off-off", at: 2.0)
            await closeTitle(view, id, close: close)
        }
        model.subtitleLook.keepFileStyle = true
    }

    // MARK: Soak

    /// What the engine's clock events did to the stack where they reach the core (`CorePlaybackBackend` calls `noteClock`).
    struct ClockProbe {
        var events = 0
        var depthFirst = 0
        var depthLast = 0
        var depthDeepest = 0
    }
    static var clockProbe = ClockProbe()

    /// One clock event reached the core: every eighth one the depth of the main stack is read.
    static func noteClock() {
        clockProbe.events += 1
        guard clockProbe.events % 8 == 1 else { return }
        let depth = Thread.callStackReturnAddresses.count
        if clockProbe.depthFirst == 0 { clockProbe.depthFirst = depth }
        clockProbe.depthLast = depth
        clockProbe.depthDeepest = max(clockProbe.depthDeepest, depth)
    }

    /// The app's own memory footprint in MB (what the system counts against it).
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// **A long film watched to the end of the run** (`-SwiftlyLiveSoakMinutes <n>`, default 45, title `-SwiftlyLiveTitles`,
    /// default `bm-soak-mkv` of `Werkzeuge/pruefstand-medien.py --soak`). Nothing is touched: the crash of build 48 came
    /// after about 25 minutes of plain watching (the driver's receiver grew by two frames per clock event). Every 30 s a
    /// `soak-sample` event says where the film is, how deep the stack is where the clock reaches the core, how often the
    /// core asked the system for a language name and how much memory the app holds; `soak-end` sums up.
    private static func scenarioSoak(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-soak-mkv"
        let minutes = Double(value("-SwiftlyLiveSoakMinutes") ?? "") ?? 45
        guard let view = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        clockProbe = ClockProbe()
        let begin = Date()
        let namesAtStart = AppPlatform.asked.withLock { $0 }
        event(["kind": "soak-start", "title": id, "minutes": minutes, "footprintMB": footprintMB(), "subtitleTracks": view.subtitleTracks.count])
        // `-SwiftlyLiveBurst <n>`: n clock events at once before the real playback (a long session's worth, as the exit scenario does),
        // so one run shows the stack depth and the memory after the burst and again after the real minutes.
        if let burst = Int(value("-SwiftlyLiveBurst") ?? ""), burst > 0 {
            let before = footprintMB()
            (view.avEngine as? CorePlaybackBackend)?.debugClockBurst(burst)
            event(["kind": "soak-burst", "asked": burst, "clockEvents": clockProbe.events, "depthFirst": clockProbe.depthFirst,
                   "depthLast": clockProbe.depthLast, "depthDeepest": clockProbe.depthDeepest, "footprintBeforeMB": before, "footprintMB": footprintMB()])
            // The burst comes through the debug call, a shorter path than the engine's own: the real playback measures its own depth.
            clockProbe.depthFirst = 0; clockProbe.depthLast = 0; clockProbe.depthDeepest = 0
        }
        var samples = 0
        while Date().timeIntervalSince(begin) < minutes * 60 {
            try? await Task.sleep(for: .seconds(30))
            samples += 1
            event(["kind": "soak-sample", "n": samples, "elapsed": Date().timeIntervalSince(begin), "position": view.positionSeconds,
                   "playing": view.isPlaying, "clockEvents": clockProbe.events, "depthFirst": clockProbe.depthFirst,
                   "depthLast": clockProbe.depthLast, "depthDeepest": clockProbe.depthDeepest,
                   "namesAsked": AppPlatform.asked.withLock { $0 } - namesAtStart, "footprintMB": footprintMB()])
        }
        let grown = clockProbe.depthLast - clockProbe.depthFirst
        event(["kind": "soak-end", "elapsed": Date().timeIntervalSince(begin), "position": view.positionSeconds, "clockEvents": clockProbe.events,
               "depthFirst": clockProbe.depthFirst, "depthLast": clockProbe.depthLast, "depthGrown": grown,
               "namesAsked": AppPlatform.asked.withLock { $0 } - namesAtStart, "footprintMB": footprintMB(),
               "ok": grown <= 2 && view.positionSeconds > 60])
        await closeTitle(view, id, close: close)
    }

    /// **Closing the player with a downloaded title while other downloads run, again and again** (`-SwiftlyLiveCycles`, default 20;
    /// the first of `-SwiftlyLiveTitles` plays from its file, the rest are the other downloads, started again before every close).
    /// Build 48 crashed on exit after about half an hour of watching: the driver's receiver was a chain of one closure context per
    /// engine event, and releasing it on close overflowed the main stack. A real session of that length is 5 000 clock events, so
    /// every cycle delivers that many before it closes (`exit-cycle` says how deep the stack stays where they reach the core);
    /// a crash ends the run silently, which `Werkzeuge/live-lauf.py` reports.
    private static func scenarioExit(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        guard let account = model.session?.storageAccount, let played = titles.first else {
            event(["kind": "result", "ok": false, "why": "no account or no title"]); return
        }
        let others = Array(titles.dropFirst())
        let cycles = Int(value("-SwiftlyLiveCycles") ?? "") ?? 20
        model.downloadsAn = true
        var items: [Item] = []
        for id in titles { if let item = await model.item(id: id) { items.append(item); knownItems[id] = item } }
        func trigger(_ list: [Item]) {
            model.downloads.trigger(list.map { f in
                let q = f.mediaSources?.first
                return DownloadItem(id: f.id, account: account, art: .film, title: f.name, runtimeTicks: f.runTimeTicks,
                                    container: q?.container, source: q?.id, bytes: q?.size ?? 0, watchState: f.userData,
                                    videoCodec: q?.videoCodec)
            })
        }
        trigger(items.filter { $0.id == played })
        _ = await waitFor(60) { model.downloads.file(for: played) != nil }
        guard model.downloads.file(for: played) != nil else { event(["kind": "result", "ok": false, "why": "no download of \(played)"]); return }
        var closed = 0
        for n in 1...cycles {
            // The other downloads start again every cycle (a finished file is removed first), so they run while the player closes.
            model.downloads.remove(others)
            trigger(items.filter { others.contains($0.id) })
            guard let view = await openTitle(model, played, open: open) else { break }
            clockProbe = ClockProbe()
            (view.avEngine as? CorePlaybackBackend)?.debugClockBurst(5_000)
            let states = model.downloads.entries.filter { others.contains($0.id) }.map { "\($0.id) \($0.state)" }
            event(["kind": "exit-cycle", "n": n, "clockEvents": clockProbe.events, "depthFirst": clockProbe.depthFirst,
                   "depthLast": clockProbe.depthLast, "othersAtClose": states, "playingFromFile": model.downloads.file(for: played) != nil,
                   "footprintMB": footprintMB()])
            await closeTitle(view, played, close: close)
            closed += 1
            event(["kind": "exit-closed", "n": n])
        }
        model.downloads.remove(items.map(\.id))
        event(["kind": "exit-end", "cycles": cycles, "closed": closed, "ok": closed == cycles])
    }

    /// **The track chosen at the start shows from the first frame** (Discord 11, TestFlight "subtitles aren't appearing": chosen
    /// automatically, drawn only after switching to another track and back). A hand pick is remembered per title, so the next
    /// open starts with it chosen by the core like the start rule does (`LoadOptions.subtitleServerIndex`): nothing is touched
    /// after the open. Samples the overlay every 100 ms for 10 s; inside a cue window (1-3, 4-6, 7-9 s, edges 0.5 s apart) the
    /// line must be on screen. `firstframe-round` says the verdict; the first sample inside a window is shot.
    private static func scenarioFirstFrame(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-multi-mkv"
        guard let first = await openTitle(model, id, open: open) else { return }
        guard let pick = textTrack(first) else { event(["kind": "result", "ok": false, "why": "no text track in \(id)"]); return }
        let want = pick.stream?.index ?? -2
        first.selectSubtitle(pick)
        _ = await waitFor(6) { (first.playingTracks.subtitle ?? -1) == want }
        await closeTitle(first, id, close: close)
        let windows: [(Double, Double)] = [(1.5, 2.5), (4.5, 5.5), (7.5, 8.5)]
        for round in 1...2 {
            guard let view = await openTitle(model, id, open: open) else { return }
            var inside = 0, shown = 0, shotTaken = false
            var firstInside: [String: Any] = [:]
            let end = Date().addingTimeInterval(10)
            while Date() < end, current() === view {
                let pos = view.positionSeconds
                let state = (view.avEngine as? CorePlaybackBackend)?.liveSubtitleState
                let line = (state?["line"] as? String) ?? ""
                if windows.contains(where: { pos >= $0.0 && pos <= $0.1 }) {
                    inside += 1
                    if !line.isEmpty { shown += 1 }
                    if firstInside.isEmpty {
                        firstInside = ["position": pos, "line": line, "engineTrack": state?["engineTrack"] ?? -1, "cues": state?["cues"] ?? -1,
                                       "playingTrack": view.playingTracks.subtitle ?? -1]
                    }
                    if !shotTaken {
                        shotTaken = true
                        await shot("\(id)--firstframe-\(round)", ["title": id, "track": "first-open-\(round)", "position": pos, "line": line])
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            event(["kind": "firstframe-round", "round": round, "want": want, "playingTrack": view.playingTracks.subtitle ?? -1,
                   "insideSamples": inside, "shownInside": shown, "firstInside": firstInside,
                   "ok": inside > 0 && Double(shown) >= Double(inside) * 0.9])
            await closeTitle(view, id, close: close)
        }
    }

    /// The start language rule: each title opens with the settings as they are (`-utAuto YES`, `-AppleLanguages (de)` come as launch
    /// arguments) and nothing chosen by hand; the event says which tracks the rule chose, in which device language.
    private static func scenarioLanguage(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        event(["kind": "settings", "audioLanguage": model.audioLanguage, "subtitleLanguage": model.subtitleLanguage,
               "automatic": model.subtitleAutomatic, "deviceLanguage": StartTracks.deviceLanguage ?? "",
               "preferred": Locale.preferredLanguages])
        for id in titles {
            guard let view = await openTitle(model, id, open: open) else { continue }
            let list = { (tracks: [SurfaceTrack]) in tracks.map { "\($0.stream?.index ?? -1) \($0.stream?.language ?? "-") \($0.prettyName)" } }
            event(["kind": "language", "title": id, "deviceLanguage": StartTracks.deviceLanguage ?? "",
                   "audioIndex": view.playingTracks.audio.map { $0 as Any } ?? NSNull(),
                   "subtitleIndex": view.playingTracks.subtitle.map { $0 as Any } ?? NSNull(),
                   "audio": list(view.audioTracks), "audioChosen": list(view.audioTracks.filter(\.isSelected)),
                   "subtitles": list(view.subtitleTracks), "subtitleChosen": list(view.subtitleTracks.filter(\.isSelected))])
            await closeTitle(view, id, close: close)
        }
    }

    /// Line 7: the start rule alone picks the track (nothing chosen by hand); the cue of the forced track is drawn.
    private static func scenarioStart(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        // The start rule picks a forced track only with the "automatic" choice and a subtitle language set (old app rule).
        model.subtitleAutomatic = true
        model.subtitleLanguage = "eng"
        event(["kind": "settings", "automatic": true, "language": "eng"])
        for id in titles {
            guard let view = await openTitle(model, id, open: open) else { continue }
            listing(view, id, "start")
            let at = Double(value("-SwiftlyLivePosition") ?? "") ?? 125.5
            await park(view, id, name: "start-chosen-by-rule", at: at)
            view.selectSubtitle(nil)
            await park(view, id, name: "start-off", at: at)
            await closeTitle(view, id, close: close)
        }
    }

    /// Lines 12 and 13: each entry once; a pick (and "off") is remembered per title across close and reopen.
    private static func scenarioMemory(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        for id in titles {
            guard var view = await openTitle(model, id, open: open) else { continue }
            listing(view, id, "first-open")
            let all = view.subtitleTracks
            let picks: [(String, SurfaceTrack?)] = [("text", all.first { ["subrip", "srt"].contains($0.stream?.codec ?? "") }),
                                                    ("off", nil),
                                                    ("bitmap", all.last { ($0.stream?.codec ?? "").contains("pgs") }),
                                                    ("text2", all.first { ["subrip", "srt"].contains($0.stream?.codec ?? "") })]
            for (label, pick) in picks {
                if label != "text" || pick == nil { /* the first pick happens in the already open player */ }
                if pick == nil && label != "off" { continue }
                view.selectSubtitle(pick)
                let want = pick?.stream?.index ?? -1
                let took = await waitFor(6) { (view.playingTracks.subtitle ?? -1) == want }
                event(["kind": "memory", "title": id, "step": "picked-\(label)", "want": want, "took": took])
                await closeTitle(view, id, close: close)
                guard let again = await openTitle(model, id, open: open) else { break }
                view = again
                let got = view.playingTracks.subtitle ?? -1
                event(["kind": "memory", "title": id, "step": "reopened-after-\(label)", "want": want, "got": got, "ok": got == want])
                listing(view, id, "reopened-after-\(label)")
            }
            await closeTitle(view, id, close: close)
        }
    }

    /// Line 6 (Apple's download path, `SubtitleFile.withLoad`): download, cut the server (the outside kills the fixture on
    /// `kill-server`), play from the file, draw the cues.
    private static func scenarioDownload(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        guard let account = model.session?.storageAccount else { event(["kind": "result", "ok": false, "why": "no account"]); return }
        // Downloads are a switch in the settings (off by default); the network watch the core waits for starts with it.
        model.downloadsAn = true
        var items: [Item] = []
        for id in titles { if let item = await model.item(id: id) { items.append(item); knownItems[id] = item } }
        model.downloads.trigger(items.map { f in
            let q = f.mediaSources?.first
            return DownloadItem(id: f.id, account: account, art: .film, title: f.name, runtimeTicks: f.runTimeTicks,
                                container: q?.container, source: q?.id, bytes: q?.size ?? 0, watchState: f.userData,
                                videoCodec: q?.videoCodec)
        })
        for second in 0..<120 where !items.allSatisfy({ model.downloads.file(for: $0.id) != nil }) {
            if second % 10 == 0 {
                event(["kind": "download-state", "entries": model.downloads.entries.map {
                    "\($0.id) \($0.state) \($0.loaded)/\($0.bytes) \($0.reason ?? "")" }])
            }
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .seconds(4))
        for f in items {
            let file = model.downloads.file(for: f.id)
            let folder = file.map { DownloadManager.subtitleFolder(to: $0) }
            let names = folder.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
            event(["kind": "downloaded", "title": f.id, "file": file != nil, "subtitleFiles": names.sorted()])
        }
        #if os(macOS)
        // The sidebar's Downloads page with the files just stored (the menu bar's shortcut), before the server goes away.
        CommandPost.dispatch(.downloads)
        try? await Task.sleep(for: .seconds(2.5))
        await shot("downloads-page", ["title": items.first?.id ?? "-", "track": "downloads-page"])
        #endif
        event(["kind": "kill-server"])
        let gate = dir.appendingPathComponent("offline-go")
        _ = await waitFor(60) { FileManager.default.fileExists(atPath: gate.path) }
        NetworkLock.an = true
        model.downloads.simulateNetwork(distance: true)
        for id in titles {
            guard let view = await openTitle(model, id, open: open) else { continue }
            // The track list of a stored file comes from the engine after the picture: wait for it.
            _ = await waitFor(10) { !view.subtitleTracks.isEmpty }
            listing(view, id, "offline")
            event(["kind": "offline", "title": id, "playing": view.isPlaying, "position": view.positionSeconds])
            for t in view.subtitleTracks where ["subrip", "srt", "mov_text", "ass", "ssa"].contains(t.stream?.codec ?? "") {
                view.selectSubtitle(t)
                _ = await waitFor(5) { (view.playingTracks.subtitle ?? -1) == (t.stream?.index ?? -2) }
                await park(view, id, name: "offline-\(t.stream?.index ?? -1)-\(t.stream?.codec ?? "x")", at: 2.0)
            }
            view.selectSubtitle(nil)
            await park(view, id, name: "offline-off", at: 2.0)
            await closeTitle(view, id, close: close)
        }
        NetworkLock.an = false
        model.downloads.simulateNetwork(distance: false)
        model.downloads.remove(items.map(\.id))
    }

    /// The chapter list of a title with chapters: the panel opens (shot), the jump the row makes goes to chapter 3, and the
    /// position must stand on its start (event + shot).
    private static func scenarioChapters(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-kapitel"
        guard let view = await openTitle(model, id, open: open) else { return }
        listing(view, id, "chapters")
        _ = await waitFor(10) { (view.coreChapters?.rows.count ?? 0) > 2 }
        let rows = view.coreChapters?.rows ?? []
        event(["kind": "chapters", "phase": "list", "title": id,
               "rows": rows.map { "\($0.index + 1) \($0.name ?? "-") \($0.start) s\($0.current ? " *" : "")" }, "ok": rows.count > 2])
        NotificationCenter.default.post(name: openLayer, object: "chapters")
        try? await Task.sleep(for: .seconds(1.5))
        await shot("chapters-list", ["title": id, "track": "chapters", "position": view.positionSeconds])
        guard rows.count > 2 else { return }
        let want = rows[2].start
        view.coreJump(toChapter: 2)
        NotificationCenter.default.post(name: openLayer, object: "none")
        _ = await waitFor(5) { abs(view.positionSeconds - want) < 1.0 }
        let now = view.coreChapters?.rows.first(where: \.current)
        event(["kind": "chapters", "phase": "jumped", "title": id, "wantStart": want, "position": view.positionSeconds,
               "runningChapter": (now?.index).map { $0 + 1 } ?? 0, "ok": abs(view.positionSeconds - want) < 1.0])
        await shot("chapters-after-jump", ["title": id, "track": "chapters-jump", "position": view.positionSeconds])
        close()
    }

    /// **The chapter list through the real remote path.** Only opens the title (paused at the start) and then WATCHES: every change of
    /// the running chapter goes to the events (`chapters-remote` / `running`), so a UI test that presses the remote (controls ->
    /// "Kapitel" -> a row) can be judged from the log. Nothing is posted to the player; the test does all the input. Ends after
    /// `-SwiftlyLiveSoakMinutes` minutes (default 3) or when the player closes.
    private static func scenarioChaptersRemote(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-kapitel"
        guard let view = await openTitle(model, id, open: open) else { return }
        view.pause()
        _ = await waitFor(10) { (view.coreChapters?.rows.count ?? 0) > 2 }
        let rows = view.coreChapters?.rows ?? []
        event(["kind": "chapters-remote", "phase": "ready", "title": id, "rows": rows.map { "\($0.index + 1) \($0.name ?? "-") \($0.start) s" }, "ok": rows.count > 2])
        var last = -1
        let end = Date().addingTimeInterval((value("-SwiftlyLiveSoakMinutes").flatMap(Double.init) ?? 3) * 60)
        while Date() < end, VLCPlayerView.playersOpen {
            let running = (view.coreChapters?.rows.first(where: \.current)?.index).map { Int($0) + 1 } ?? 0
            if running != last {
                last = running
                event(["kind": "chapters-remote", "phase": "running", "title": id, "runningChapter": running, "position": view.positionSeconds])
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        close()
    }

    /// **The next-episode countdown waits while a menu is open** (iPhone): the 330 s `bm-ep1` of the `swiftly-live-media-b6a` fixture
    /// (no markers, resumed at 315 s, the server with `SWIFTLY_FIXTURE_NO_MARKERS=1`) opens the card for the last seven seconds. Once
    /// the card is up the "Ton & Untertitel" menu opens: the card's fill value is read twice while it is open (equal) and once after
    /// it closed (larger). Four shots; the values are in the `menus-countdown` event.
    private static func scenarioMenusCountdown(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-ep1"
        guard let first = await openTitle(model, id, open: open) else { return }
        NotificationCenter.default.post(name: hideControls, object: nil)
        var cardUp = false
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            if case .card = (current()?.avEngine as? CorePlaybackBackend)?.offerNow { cardUp = true; break }
        }
        guard cardUp else {
            event(["kind": "menus-countdown", "error": "the card never opened"])
            await closeTitle(current() ?? first, id, close: close)
            return
        }
        func fill() -> Double { ((countdownRunProbe ?? -1) * 1000).rounded() / 1000 }
        // The Apple TV simulator needs seconds for a screenshot, and the card lives only seven: there the values are read
        // first and a single picture of the open menu follows.
        #if os(tvOS)
        let quick = true
        #else
        let quick = false
        #endif
        func snap(_ name: String, shoot: Bool = true) async -> Double {
            let value = fill()
            if shoot { await shot(name, ["title": id, "track": name, "fill": value, "position": current()?.positionSeconds ?? -1]) }
            return value
        }
        try? await Task.sleep(for: .milliseconds(400))
        let running = await snap("countdown-1-laeuft", shoot: !quick)
        NotificationCenter.default.post(name: openLayer, object: "tracks")
        try? await Task.sleep(for: .milliseconds(500))
        let open1 = await snap("countdown-2-menue-offen", shoot: !quick)
        try? await Task.sleep(for: .milliseconds(1200))
        let open2 = await snap("countdown-3-menue-offen-spaeter")
        NotificationCenter.default.post(name: openLayer, object: "none")
        try? await Task.sleep(for: .milliseconds(600))
        let closed = await snap("countdown-4-menue-zu")
        event(["kind": "menus-countdown", "running": running, "open1": open1, "open2": open2, "closed": closed,
               "frozen": open1 == open2, "movesAfter": closed > open2])
        await closeTitle(current() ?? first, id, close: close)
    }

    /// Speed and subtitle offset through the core's menu rows (the calls the menu rows make): 1.5x must advance the position
    /// 1.5x as fast as the wall clock, and an offset of +1.0 s must move the cue (nominally 1-3 s) one second later.
    /// **The player's menu boxes in the real player** (iPhone): `bm-tracks45` shows "Ton & Untertitel" with its long list and
    /// "Zeit anpassen"; the episode `bm-ep1` shows "Optionen", the episodes panel with the season button switched to season 2
    /// and "Übergeben an …". Steps go through `openLayer` (see `PlayerScreen`).
    private static func scenarioMenus(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-ep1"
        guard let view = await openTitle(model, id, open: open) else { return }
        listing(view, id, "menus")
        try? await Task.sleep(for: .seconds(2))
        func step(_ what: String, _ name: String, wait: Double = 1.3) async {
            NotificationCenter.default.post(name: openLayer, object: what)
            try? await Task.sleep(for: .seconds(wait))
            await shot(name, ["title": id, "track": name, "position": view.positionSeconds])
        }
        if id == "bm-tracks45" {
            await step("tracks", "menus-ton-untertitel")
            await step("scroll", "menus-ton-gescrollt")
            await step("time", "menus-zeit-anpassen")
            await step("look", "menus-aussehen")
            await step("none", "menus-closed-3", wait: 0.6)
            await step("audio", "menus-ton")
            await step("none", "menus-closed", wait: 0.6)
            // Frame 15: the intro offer (2 s to 5 s in the fixture) with the track menu open.
            view.seek(toSeconds: 2.6)
            try? await Task.sleep(for: .seconds(0.4))
            await step("tracks", "menus-intro-offen", wait: 0.8)
        } else {
            // Frame 16 runs first, on the first episode, before any earlier step lets the countdown advance the clip:
            // the next-episode offer (outro 6 s to 10 s in the fixture) with the track menu open. The countdown value is
            // shot while the menu is open (twice, frozen) and again after it closed (moving).
            view.seek(toSeconds: 6.4)
            try? await Task.sleep(for: .seconds(0.4))
            await step("tracks", "menus-naechste-folge-offen", wait: 0.6)
            try? await Task.sleep(for: .seconds(0.8))
            await shot("menus-naechste-folge-offen-spaeter", ["title": id, "track": "menus-naechste-folge-offen-spaeter", "position": view.positionSeconds])
            await step("none", "menus-naechste-folge-zu", wait: 0.8)
            // Back to the start so the later steps still run on this episode.
            view.seek(toSeconds: 0.5)
            try? await Task.sleep(for: .seconds(0.6))
            await step("settings", "menus-optionen")
            await step("sleep", "menus-schlafzeit")
            await step("quality", "menus-qualitaet")
            await step("none", "menus-closed", wait: 0.6)
            await step("pill", "menus-pille-oeffnet", wait: 2)
            await step("none", "menus-closed-pille", wait: 0.8)
            await step("episodes", "menus-folgen-staffel-1", wait: 2)
            await step("seasons", "menus-staffelwahl")
            await step("season2", "menus-folgen-staffel-2", wait: 2)
            await step("kapitel", "menus-kapitel")
            await step("tapfirst", "menus-folgen-gestartet", wait: 3)
            await step("none", "menus-closed-2", wait: 0.6)
            await step("handoff", "menus-uebergeben")
            await step("handoffbusy", "menus-uebergeben-laedt", wait: 0.6)
            await step("none", "menus-closed-4", wait: 0.6)
        }
        NotificationCenter.default.post(name: openLayer, object: "none")
        close()
    }

    /// **Skip intro** (Mac): the fixture's intro runs 2 s to 5 s; with the offer showing, its press must land the position at the end of it.
    private static func scenarioSkipIntro(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-tracks45"
        guard let view = await openTitle(model, id, open: open) else { return }
        try? await Task.sleep(for: .seconds(2))
        view.seek(toSeconds: 2.6)
        try? await Task.sleep(for: .seconds(1))
        let before = view.positionSeconds
        await shot("skip-intro-offer", ["title": id, "track": "skip-intro-offer", "position": before])
        NotificationCenter.default.post(name: openLayer, object: "offer")
        try? await Task.sleep(for: .seconds(1.5))
        let after = view.positionSeconds
        event(["kind": "skip-intro", "title": id, "before": before, "after": after, "ok": before < 5 && after >= 5])
        await shot("skip-intro-after", ["title": id, "track": "skip-intro-after", "position": after])
        close()
    }

    /// **Open, close and the switch between the capsule's two menus** in the real player, for a screen recording: every step
    /// logs its wall-clock time (`motion` events) so the frames of the video can be cut around it.
    private static func scenarioMenuMotion(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-ep3"
        guard let view = await openTitle(model, id, open: open) else { return }
        listing(view, id, "menu-motion")
        try? await Task.sleep(for: .seconds(3))
        func step(_ what: String, wait: Double = 1.6) async {
            event(["kind": "motion", "step": what, "t": Date().timeIntervalSince1970])
            NotificationCenter.default.post(name: openLayer, object: what)
            try? await Task.sleep(for: .seconds(wait))
        }
        await step("settings")
        await step("tracks")
        await step("none", wait: 1.2)
        await step("tracks")
        await step("none", wait: 1.2)
        await step("episodes", wait: 2.5)
        await shot("menu-motion-folgen", ["title": id, "track": "folgen", "position": view.positionSeconds])
        await step("seasons", wait: 1.2)
        await shot("menu-motion-staffelliste", ["title": id, "track": "staffelliste", "position": view.positionSeconds])
        await step("none", wait: 0.8)
        event(["kind": "motion", "step": "end", "t": Date().timeIntervalSince1970])
        close()
    }

    /// **The top bar in the real player**: controls shown and idle, the volume pill dropped down, the subtitles menu open.
    private static func scenarioPlayerBar(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-ep1"
        guard let view = await openTitle(model, id, open: open) else { return }
        listing(view, id, "player-bar")
        try? await Task.sleep(for: .seconds(2))
        func step(_ what: String, _ name: String, wait: Double = 1.3) async {
            NotificationCenter.default.post(name: openLayer, object: what)
            try? await Task.sleep(for: .seconds(wait))
            await shot(name, ["title": id, "track": name, "position": view.positionSeconds])
        }
        await step("controls", "bar-1-idle", wait: 1.0)
        await step("volume", "bar-2-volume", wait: 1.0)
        await step("none", "bar-3-closed", wait: 0.8)
        await step("tracks", "bar-4-untertitel", wait: 1.3)
        await step("none", "bar-5-closed", wait: 0.6)
        close()
    }

    private static func scenarioMenu(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-multi-mkv"
        guard var view = await openTitle(model, id, open: open) else { return }
        listing(view, id, "menu")
        view.selectSubtitle(textTrack(view))
        let index = textTrack(view)?.stream?.index ?? -2
        _ = await waitFor(5) { (view.playingTracks.subtitle ?? -1) == index }
        func current() -> VLCPlayerView? { view }
        func rows() -> [String: Any] {
            guard let m = view.playerMenu() else { return [:] }
            return ["speeds": m.speeds.map { "\($0.label)\($0.selected ? "*" : "")" }, "offsetText": m.offsetText, "offsetMs": m.offsetMs,
                    "steps": m.offsetSteps.map(\.label), "canReset": m.canReset]
        }
        event(["kind": "menu", "phase": "rows-at-start", "rows": rows(), "ok": view.playerMenu()?.speeds.first(where: \.selected)?.value == 1])
        // Speed: normal for 3 s of wall clock, then 1.5x for 4 s.
        func rate(_ phase: String, seconds: Double, want: Double) async {
            let (p0, t0) = (view.positionSeconds, Date())
            try? await Task.sleep(for: .seconds(seconds))
            let (p1, t1) = (view.positionSeconds, Date())
            let ratio = (p1 - p0) / t1.timeIntervalSince(t0)
            event(["kind": "menu", "phase": phase, "positionFrom": p0, "positionTo": p1, "wall": t1.timeIntervalSince(t0), "ratio": ratio,
                   "want": want, "ok": abs(ratio - want) < 0.15 * want])
        }
        await rate("speed-1x", seconds: 2, want: 1)
        view.tempo = 1.5
        event(["kind": "menu", "phase": "rows-at-1.5", "rows": rows(), "ok": view.playerMenu()?.speeds.first(where: \.selected)?.value == 1.5])
        try? await Task.sleep(for: .seconds(0.5))
        // The fixture is about 10 s long: the window ends before the file does.
        await rate("speed-1.5x", seconds: 2.5, want: 1.5)
        NotificationCenter.default.post(name: openLayer, object: "settings")
        try? await Task.sleep(for: .seconds(1.2))
        await shot("menu-speed-1.5x", ["title": id, "track": "menu-speed", "position": view.positionSeconds])
        NotificationCenter.default.post(name: openLayer, object: "none")
        view.tempo = 1
        // Subtitle offset: the position where the first cue shows and goes away again, from the overlay line.
        func cueEdges(_ phase: String, shift: Double) async {
            view.pause(); view.seek(toSeconds: 0.3); try? await Task.sleep(for: .seconds(1)); _ = view.resume()
            var appeared: Double?, vanished: Double?
            let end = Date().addingTimeInterval(9)
            while Date() < end, let v = current() {
                let pos = v.positionSeconds
                let line = ((v.avEngine as? CorePlaybackBackend)?.liveSubtitleState?["line"] as? String) ?? ""
                if appeared == nil, !line.isEmpty { appeared = pos }
                if appeared != nil, vanished == nil, line.isEmpty, pos > (appeared ?? 0) + 0.3 { vanished = pos; break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            let a = appeared ?? -1, d = vanished ?? -1
            event(["kind": "menu", "phase": phase, "cueAppearedAt": a, "cueVanishedAt": d, "shift": shift, "rows": rows(),
                   "ok": a >= 0 && d >= 0 && abs(a - (1 + shift)) < 0.6 && abs(d - (3 + shift)) < 0.6])
        }
        await cueEdges("offset-0", shift: 0)
        view.offsetStep(500); view.offsetStep(500)
        await cueEdges("offset-plus-1s", shift: 1)
        NotificationCenter.default.post(name: openLayer, object: "tracks")
        try? await Task.sleep(for: .seconds(1.2))
        await shot("menu-offset-plus-1s", ["title": id, "track": "menu-offset", "position": view.positionSeconds])
        NotificationCenter.default.post(name: openLayer, object: "none")
        view.offsetStep(-500)
        event(["kind": "menu", "phase": "offset-minus-half", "rows": rows(), "ok": view.playerMenu()?.offsetMs == 500])
        view.offsetReset()
        event(["kind": "menu", "phase": "offset-reset", "rows": rows(), "ok": view.playerMenu()?.offsetMs == 0 && view.playerMenu()?.canReset == false])
        close()
    }

    /// Line 14: with a text track on, the line the overlay shows follows the cue windows (1-3, 4-6, 7-9 s) after
    /// pause/resume, at 2x, after a quality change (re-plan at the same position) and with a subtitle delay of +2 s.
    private static func scenarioTiming(_ model: AppModel, open: @escaping (PlayRequest) -> Void, close: @escaping () -> Void) async {
        let id = titles.first ?? "bm-multi-mkv"
        guard var view = await openTitle(model, id, open: open) else { return }
        listing(view, id, "timing")
        view.selectSubtitle(textTrack(view))
        let index = textTrack(view)?.stream?.index ?? -2
        _ = await waitFor(5) { (view.playingTracks.subtitle ?? -1) == index }
        let windows: [(Double, Double)] = [(1, 3), (4, 6), (7, 9)]

        /// Samples (position, line) every 80 ms until `until` or `limit` s; counts the clear mismatches (edges +-0.5 s excepted).
        func sample(_ phase: String, delay: Double = 0, until: Double, limit: Double = 12) async {
            var n = 0, bad = 0, shownRight = 0, details: [String] = []
            let end = Date().addingTimeInterval(limit)
            while Date() < end, let v = current() {
                let pos = v.positionSeconds
                if pos >= until { break }
                let line = ((v.avEngine as? CorePlaybackBackend)?.liveSubtitleState?["line"] as? String) ?? ""
                let inside = windows.contains { pos - delay >= $0.0 + 0.5 && pos - delay <= $0.1 - 0.5 }
                let outside = windows.allSatisfy { pos - delay < $0.0 - 0.5 || pos - delay > $0.1 + 0.5 }
                if inside || outside {
                    n += 1
                    if inside && !line.isEmpty { shownRight += 1 }
                    if (inside && line.isEmpty) || (outside && !line.isEmpty) {
                        bad += 1
                        if details.count < 4 { details.append(String(format: "%.2f:%@", pos, line.isEmpty ? "none" : line)) }
                    }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            event(["kind": "timing", "phase": phase, "samples": n, "mismatch": bad, "shownInside": shownRight, "details": details,
                   "delay": delay, "ok": bad == 0 && shownRight > 0])
        }

        // Pause and resume inside a cue (line must stay while paused, clear after the cue ends).
        view.pause(); view.seek(toSeconds: 0.3); try? await Task.sleep(for: .seconds(1)); _ = view.resume()
        await sample("play-to-1.8", until: 1.8)
        view.pause(); try? await Task.sleep(for: .seconds(1.5))
        let heldLine = ((view.avEngine as? CorePlaybackBackend)?.liveSubtitleState?["line"] as? String) ?? ""
        event(["kind": "timing", "phase": "paused-in-cue", "line": heldLine, "ok": !heldLine.isEmpty])
        _ = view.resume()
        await sample("after-resume", until: 6.5)
        // 2x speed.
        view.tempo = 2; view.pause(); view.seek(toSeconds: 0.3); try? await Task.sleep(for: .seconds(1)); _ = view.resume()
        await sample("speed-2x", until: 9.5, limit: 10)
        view.tempo = 1
        // Subtitle delay +2 s.
        view.subtitleDelay = Delay(milliseconds: 2000)
        view.pause(); view.seek(toSeconds: 0.3); try? await Task.sleep(for: .seconds(1)); _ = view.resume()
        await sample("delay-plus-2s", delay: 2, until: 9.5, limit: 12)
        view.subtitleDelay = .null
        // Quality change: a re-plan at the same position.
        view.pause(); view.seek(toSeconds: 0.3); try? await Task.sleep(for: .seconds(1)); _ = view.resume()
        try? await Task.sleep(for: .seconds(1))
        // A quality choice replaces the engine (and, for a new plan, the picture). Watch both: a direct play re-plan keeps the
        // screen's view and starts a new engine at the same position.
        let before = view
        let engineBefore = view.avEngine.map { ObjectIdentifier($0 as AnyObject) }
        NotificationCenter.default.post(name: chooseQuality, object: qualityLimit)
        let reloaded = await waitFor(25) {
            guard let now = current(), now.showsImage else { return false }
            return now !== before || now.avEngine.map({ ObjectIdentifier($0 as AnyObject) }) != engineBefore
        }
        if let next = current() { view = next }
        try? await Task.sleep(for: .seconds(2))
        event(["kind": "timing", "phase": "quality-reloaded", "reloaded": reloaded, "newView": view !== before,
               "position": view.positionSeconds, "subtitle": view.playingTracks.subtitle ?? -1, "ok": reloaded])
        // The re-plan carries the chosen text track on (the core hands the choice to the new load).
        _ = await waitFor(5) { (view.playingTracks.subtitle ?? -1) == index }
        event(["kind": "timing", "phase": "quality-track-kept", "subtitle": view.playingTracks.subtitle ?? -1, "want": index,
               "ok": (view.playingTracks.subtitle ?? -1) == index])
        view.pause(); view.seek(toSeconds: 3.5); try? await Task.sleep(for: .seconds(1.5)); _ = view.resume()
        await sample("after-quality", until: 9.5)
        await closeTitle(view, id, close: close)
    }
}
#endif
