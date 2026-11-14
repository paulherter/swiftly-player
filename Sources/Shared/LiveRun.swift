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

    /// Posted before a shot: the player hides its controls so the picture and the subtitle are bare.
    nonisolated static let hideControls = Notification.Name("SwiftlyLiveHideControls")
    /// tvOS: bring the controls back for the controls shot.
    nonisolated static let showControls = Notification.Name("SwiftlyLiveShowControls")
    /// iOS: a quality choice as the quality layer makes it; the object is the limit in Mbit/s (`nil` = original).
    nonisolated static let chooseQuality = Notification.Name("SwiftlyLiveChooseQuality")

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
            let details = PlexSessionDetails(machineIdentifier: "plexfx", serverName: "Fixture Plex",
                                             accountToken: "fixture", isLocal: true)
            return Session(accessToken: "fixture", userID: "demo", userName: "demo",
                           serverURL: address, kind: .plex, plex: details)
        }
        return Session(accessToken: "fixture", userID: "u1", userName: "demo", serverURL: address)
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

    private static func event(_ fields: [String: Any]) {
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
                   "pipPossible": pipPossible(view)])
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
        case "pausedseek": await scenarioPausedSeek(model, open: open, close: close)
        default: event(["kind": "result", "ok": false, "why": "unknown scenario \(name)"])
        }
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
