import CGtk
import CMPV
import CMPVBridge
import Foundation
import JellyfinKit

/// **The player** (Linux and Windows): libmpv, the only engine. LGPL; on Linux the system
/// library is linked dynamically, on Windows the LGPL build is shipped next to the program.
///
/// - Picture: libmpv's render API into a `GtkGLArea` (`mpvbridge.c`). The mpv core
///   lives as long as the player. The GL context does not: when the area is
///   unrealized (page change, fullscreen re-parenting) only the render context is
///   freed and recreated on `realize`; playback keeps running.
/// - Events: a thread of its own waits in `mpv_wait_event`; results are handed to
///   GTK's main thread.
/// - Position and tracks are read from properties on demand (thread safe in libmpv).
final class Player: @unchecked Sendable {

    private var handle: OpaquePointer?
    private var gl: OpaquePointer?          // MpvGL *
    private var glField: Widget!
    private var wrapper: Widget!
    private var eventDone = DispatchSemaphore(value: 0)
    private var stopping = false
    private var hasEvents = false
    private let headless: Bool

    private(set) var fetchedImages = 0      // frames rendered by the GL area
    private(set) var drawsWithoutGPU = false
    private(set) var beats = 0
    fileprivate var glWidth: Int32 = 0
    fileprivate var glHeight: Int32 = 0

    var display: Widget! { wrapper }
    var runState: ((Bool) -> Void)?
    var tornDown: ((Bool) -> Void)?
    var look: SubtitleLook
    /// For the log and the licenses page: the libmpv client API this build runs against.
    static var engineVersion: String {
        let v = mpv_client_api_version()
        return "libmpv API \(v >> 16).\(v & 0xFFFF)"
    }
    var ready: Bool { handle != nil }
    var tickStatus: String { "libmpv gl=\(gl != nil ? 1 : 0) bilder=\(fetchedImages)" }

    /// `headless` is for the probe on machines without a display: no GL area, `vo=null`,
    /// `ao=null`.
    init(look: SubtitleLook = .standard, headless: Bool = false) {
        self.look = look
        self.headless = headless
        // libmpv refuses to start (mpv_create returns NULL) unless LC_NUMERIC is "C", and
        // gtk_init sets the user's locale (German: decimal comma). Measured on Windows.
        setlocale(LC_NUMERIC, "C")
        guard let h = mpv_create() else {
            AppLog.writeOut("[MPV] mpv_create fehlgeschlagen")
            return
        }
        func opt(_ n: String, _ v: String) { mpv_set_option_string(h, n, v) }
        opt("config", "no")
        opt("terminal", "no")
        opt("load-scripts", "no")
        opt("osc", "no")
        opt("input-default-bindings", "no")
        opt("input-vo-keyboard", "no")
        opt("ytdl", "no")
        opt("sub-auto", "no")
        opt("audio-display", "no")
        opt("keep-open", "no")
        opt("idle", "yes")
        // **Every build logs warnings**, as with VLC: a user's log needs the line about
        // a missing decoder or a failed hardware path. `=v`/`=debug` via the variable.
        let level = ProcessInfo.processInfo.environment["SWIFTLY_MPV_MELDUNGEN"] ?? "warn"
        opt("msg-level", "all=\(level)")
        opt("hwdec", "auto-safe")
        opt("video-sync", "audio")
        if headless {
            opt("vo", "null"); opt("ao", "null")
        } else {
            opt("vo", "libmpv")
        }
        guard mpv_initialize(h) >= 0 else {
            AppLog.writeOut("[MPV] mpv_initialize fehlgeschlagen")
            mpv_destroy(h)
            return
        }
        handle = h
        mpv_request_log_messages(h, level == "warn" ? "warn" : level)
        for (i, name) in ["pause", "core-idle"].enumerated() {
            mpv_observe_property(h, UInt64(i + 1), name, MPV_FORMAT_FLAG)
        }
        applyLook()
        eventsStart()
        guard !headless else { return }
        glField = gtk_gl_area_new()
        wrapper = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        // Outlives its page, see `Player.init`.
        g_object_ref_sink(wrapper)
        for w in [wrapper!, glField!] {
            gtk_widget_set_hexpand(w, 1); gtk_widget_set_vexpand(w, 1)
        }
        let area = asGLArea(glField)
        gtk_gl_area_set_auto_render(area, 0)
        gtk_gl_area_set_has_depth_buffer(area, 0)
        gtk_box_append(UnsafeMutableRawPointer(wrapper).assumingMemoryBound(to: GtkBox.self),
                       Scaling.unwarped(glField))
        let me = Unmanaged.passUnretained(self).toOpaque()
        for (name, call) in [("realize", unsafeBitCast(mpvRealizeCall, to: GCallback.self)),
                             ("unrealize", unsafeBitCast(mpvUnrealizeCall, to: GCallback.self))] {
            g_signal_connect_data(UnsafeMutableRawPointer(glField), name, call, me, nil,
                                  GConnectFlags(rawValue: 0))
        }
        g_signal_connect_data(UnsafeMutableRawPointer(glField), "render",
                              unsafeBitCast(mpvRenderCall, to: GCallback.self), me, nil,
                              GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(glField), "resize",
                              unsafeBitCast(mpvSizeCall, to: GCallback.self), me, nil,
                              GConnectFlags(rawValue: 0))
    }

    // MARK: Property helpers (thread safe in libmpv)

    private func double(_ name: String) -> Double? {
        guard let handle else { return nil }
        var v = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }
    private func int(_ name: String) -> Int? {
        guard let handle else { return nil }
        var v: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &v) >= 0 ? Int(v) : nil
    }
    private func flag(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var v: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 ? v != 0 : nil
    }
    private func string(_ name: String) -> String? {
        guard let handle, let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }
    @discardableResult
    private func set(_ name: String, _ value: String) -> Bool {
        guard let handle else { return false }
        return mpv_set_property_string(handle, name, value) >= 0
    }
    @discardableResult
    private func command(_ args: [String]) -> Bool {
        guard let handle else { return false }
        var cs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cs.append(nil)
        defer { cs.forEach { free($0) } }
        var raw = cs.map { UnsafePointer<CChar>($0) }
        return mpv_command(handle, &raw) >= 0
    }

    // MARK: Opening

    private var lastOpenedAt = Date.distantPast
    func open(_ url: URL, since: Double, buffer: BufferLevel, paused: Bool = false,
              softwareDecoder: Bool = false, curve: ColorRange.IdLine? = nil) {
        guard handle != nil else {
            AppLog.writeOut("[MPV] kein Kern, Titel kann nicht spielen")
            onMainThread { [weak self] in self?.tornDown?(true) }
            return
        }
        pausedSince = nil
        leapAt = nil; fetchedImages = 0; beats = 0
        applyLook()
        // Behind an outpost the app fetches the stream itself (issue #4).
        let address = StreamForwarder.gemeinsam.address(for: url)
        if address != url { AppLog.writeOut("[MPV] Strom über den Weiterleiter") }
        // **Position as an option before loading** (VLC: `:start-time`); a seek after
        // the start would set the stream up twice.
        set("start", since > 1 ? String(Int(since)) : "none")
        set("pause", paused ? "yes" : "no")
        // XviD/DivX: hardware decoders accept the stream and fail on Advanced Simple
        // Profile (see `PlaybackPlan.softwareDekoder`).
        set("hwdec", softwareDecoder ? "no" : "auto-safe")
        if !url.isFileURL {
            // Same three levels as VLC's prefetch size (`BufferLevel`).
            set("cache", "yes")
            set("demuxer-max-bytes", String(buffer.prefetchKiB * 1024))
            set("demuxer-max-back-bytes", String(buffer.prefetchKiB * 256))
            if let lead = buffer.networkLeadMilliseconds {
                set("cache-secs", String(max(lead / 1000, 10)))
            }
            // Counterpart of `:http-reconnect`: the server drops idle streams after ~25 s.
            set("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")
        }
        set("volume", String(volumePercent))
        AppLog.writeOut("[MPV] oeffne \(url.isFileURL ? "Datei" : "Netz")"
            + " \(url.pathExtension.isEmpty ? "ohne Endung" : url.pathExtension)"
            + ", ab \(Int(since)) s, Puffer \(buffer)" + (softwareDecoder ? ", Dekoder Software" : ""))
        command(["loadfile", address.isFileURL ? address.path : address.absoluteString, "replace"])
        lastOpenedAt = Date()
        delayCatchUp()
    }

    // MARK: Transport

    private(set) var volumePercent: Int32 = 100
    func volumeSet(_ percent: Int) {
        volumePercent = Int32(min(max(percent, 0), 100))
        set("mute", "no")
        set("volume", String(volumePercent))
    }
    func volumeCatchUp() {
        guard let v = double("volume"), Int32(v.rounded()) != volumePercent else { return }
        set("volume", String(volumePercent))
    }
    func play() { set("pause", "no") }
    func halt() {
        if pausedSince == nil { pausedSince = Date() }
        set("pause", "yes")
    }
    func toggle() { running ? halt() : play() }
    private(set) var pausedSince: Date?
    #if DEBUG
    func pausedSincePreSet(_ seconds: Double) { pausedSince = Date().addingTimeInterval(-seconds) }
    #endif
    fileprivate func runStateRemember(_ running: Bool) {
        if running { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
    }
    var running: Bool { flag("pause") == false && flag("idle-active") != true }
    var position: Double { max(double("time-pos") ?? 0, 0) }
    var duration: Double { max(double("duration") ?? 0, 0) }
    var showsImage: Bool { flag("vo-configured") == true }
    var hasAudioTracks: Bool { !audioTracks.isEmpty }
    var seeksToStart: Bool { flag("seeking") == true || flag("paused-for-cache") == true }

    func setTime(_ seconds: Double) {
        let from = position
        AppLog.writeOut(String(format: "[MPV] springe %@ auf %.0f s (von %.0f s, Bilder bisher %d)",
                               seconds >= from ? "vor" : "zurueck", max(0, seconds), from, fetchedImages))
        leapAt = fetchedImages
        jumpSince = Date()
        command(["seek", String(max(0, seconds)), "absolute"])
    }
    private(set) var leapAt: Int?
    private var jumpSince = Date.distantPast
    func jumpBalance() -> Int? {
        guard let at = leapAt, Date().timeIntervalSince(jumpSince) >= 1 else { return nil }
        leapAt = nil
        return fetchedImages - at
    }
    func jump(_ seconds: Double) { setTime(max(0, position + seconds)) }

    var tempo: Float {
        get { Float(double("speed") ?? 1) }
        set { set("speed", String(newValue)) }
    }

    /// Cover (true) or contain: mpv's `panscan`.
    func fillFrame(_ an: Bool) {
        set("panscan", an ? "1.0" : "0.0")
        if let glField { gtk_gl_area_queue_render(asGLArea(glField)) }
    }

    func unstretchGLArea() {
        guard Scaling.factor != 1, let wrapper, let glField,
              gtk_widget_get_parent(glField) == wrapper else { return }
        g_object_ref(glField)
        gtk_box_remove(UnsafeMutableRawPointer(wrapper).assumingMemoryBound(to: GtkBox.self), glField)
        gtk_box_append(UnsafeMutableRawPointer(wrapper).assumingMemoryBound(to: GtkBox.self),
                       Scaling.unwarped(glField))
        g_object_unref(glField)
    }

    // MARK: Tracks (mpv ids start at 1; -1 = off, as in libVLC)

    struct TrackSupport { let identifier: Int32; let name: String }
    struct TrackDetail { let codec: String?; let language: String?; let channels: Int? }

    private func trackEntries(_ type: String) -> [(id: Int32, title: String?, lang: String?,
                                                    codec: String?, channels: Int?)] {
        guard let n = int("track-list/count") else { return [] }
        var out: [(Int32, String?, String?, String?, Int?)] = []
        for i in 0..<n where string("track-list/\(i)/type") == type {
            guard let id = int("track-list/\(i)/id") else { continue }
            out.append((Int32(id), string("track-list/\(i)/title"), string("track-list/\(i)/lang"),
                        string("track-list/\(i)/codec"), int("track-list/\(i)/demux-channel-count")))
        }
        return out
    }
    private func trackList(_ type: String) -> [TrackSupport] {
        trackEntries(type).map {
            let name = $0.title ?? "Track \($0.id)"
            return TrackSupport(identifier: $0.id, name: $0.lang.map { "\(name) - [\($0)]" } ?? name)
        }
    }
    /// Subtitle ids are offset so audio and subtitle ids never collide (libVLC's ids were
    /// unique across kinds, and `trackDetails()` is one dictionary).
    static let subtitleBase: Int32 = 1000
    var audioTracks: [TrackSupport] { trackList("audio") }
    /// Includes the "off" row (-1) like libVLC's list did.
    var subtitleTracks: [TrackSupport] {
        let t = trackList("sub").map { TrackSupport(identifier: $0.identifier + Player.subtitleBase, name: $0.name) }
        return t.isEmpty ? [] : [TrackSupport(identifier: -1, name: "Disable")] + t
    }
    func setAudioTrack(_ identifier: Int32) { set("aid", identifier < 0 ? "no" : String(identifier)) }
    func setSubtitle(_ identifier: Int32) { set("sid", identifier < 0 ? "no" : String(identifier - Player.subtitleBase)) }
    var audioTrack: Int32 { Int32(int("aid") ?? -1) }
    var subtitleTrack: Int32 { int("sid").map { Int32($0) + Player.subtitleBase } ?? -1 }

    func trackDetails() -> [Int32: TrackDetail] {
        var d: [Int32: TrackDetail] = [:]
        for type in ["audio", "sub"] {
            for e in trackEntries(type) {
                d[type == "sub" ? e.id + Player.subtitleBase : e.id] = TrackDetail(codec: e.codec, language: e.lang, channels: e.channels)
            }
        }
        return d
    }

    @discardableResult
    func subtitleFileAppend(_ address: URL) -> Bool {
        let a = StreamForwarder.gemeinsam.address(for: address)
        return command(["sub-add", a.isFileURL ? a.path : a.absoluteString, "select"])
    }

    // MARK: Delay (mpv: seconds; audio-delay has the opposite sign to VLC's)

    var subtitleDelay = Delay.null { didSet { if subtitleDelay != oldValue { delayCatchUp() } } }
    var audioDelay = Delay.null { didSet { if audioDelay != oldValue { delayCatchUp() } } }

    func delayForNewTitle(oldTitle: String, oldSeries: String?, newTitle: String, addedSeries: String?) {
        subtitleDelay = .forNewTitle(subtitleDelay, oldTitle: oldTitle, oldSeries: oldSeries,
                                     newTitle: newTitle, addedSeries: addedSeries)
        audioDelay = .forNewTitle(audioDelay, oldTitle: oldTitle, oldSeries: oldSeries,
                                  newTitle: newTitle, addedSeries: addedSeries)
    }
    func delayCatchUp() {
        guard handle != nil else { return }
        let sub = Double(subtitleDelay.microseconds) / 1_000_000
        // mpv: positive audio-delay plays the audio EARLIER; libVLC's positive value
        // delays it. The package's `Delay` follows VLC, hence the minus.
        let audio = -Double(audioDelay.microseconds) / 1_000_000
        if abs((double("sub-delay") ?? 0) - sub) > 0.0005 {
            set("sub-delay", String(sub))
            AppLog.writeOut("[Verzögerung] Untertitel \(subtitleDelay.milliseconds) ms gesetzt, mpv liest \(double("sub-delay") ?? .nan) s")
        }
        if abs((double("audio-delay") ?? 0) - audio) > 0.0005 {
            set("audio-delay", String(audio))
            AppLog.writeOut("[Verzögerung] Ton \(audioDelay.milliseconds) ms gesetzt, mpv liest \(double("audio-delay") ?? .nan) s")
        }
    }

    // MARK: Counters and tech values

    var countValues: Counter.RawValues? {
        guard handle != nil, flag("idle-active") != true else { return nil }
        func u(_ n: String) -> UInt64 { UInt64(max(int(n) ?? 0, 0)) }
        return Counter.RawValues(
            hasRead: u("cache-speed") == 0 ? UInt64(max(double("demuxer-cache-state/fw-bytes") ?? 0, 0)) : 0,
            unpacked: 0,
            shown: u("estimated-frame-number"), discarded: u("decoder-frame-drop-count"),
            tooLate: u("vo-delayed-frame-count"),
            videoBlocks: u("estimated-frame-number"), audioBlocks: 0, audioPlay: 0, audioLost: 0,
            beschaedigt: 0, jumps: 0)
    }

    /// Values for the tech badge (video/audio format, decoder, HDR transfer).
    struct TechValues {
        var videoCodec: String?, width: Int?, height: Int?, fps: Double?
        var hwdec: String?, transfer: String?, primaries: String?
        var audioCodec: String?, channels: Int?, audioDevice: String?
    }
    func techValues() -> TechValues {
        TechValues(videoCodec: string("video-codec"), width: int("video-params/w"),
                   height: int("video-params/h"), fps: double("container-fps"),
                   hwdec: string("hwdec-current"), transfer: string("video-params/gamma"),
                   primaries: string("video-params/primaries"),
                   audioCodec: string("audio-codec-name"), channels: int("audio-params/channel-count"),
                   audioDevice: string("current-ao"))
    }

    /// Audio passthrough and exclusive access (WASAPI on Windows), prepared as switches:
    /// off by default, effective from the next title.
    func passthrough(spdif codecs: String?, exclusive: Bool) {
        set("audio-spdif", codecs ?? "")
        set("audio-exclusive", exclusive ? "yes" : "no")
    }

    // MARK: Subtitle look

    private func applyLook() {
        for (n, v) in SubtitleStyle.mpvOptions(look: look, outputHeight: SubtitleStyle.outputHeight()) {
            set(n, v)
        }
    }

    // MARK: Events

    private func eventsStart() {
        guard let handle, !hasEvents else { return }
        hasEvents = true
        let addr = UInt(bitPattern: handle)
        let done = eventDone
        let thread = Thread { [weak self] in
            let h = OpaquePointer(bitPattern: addr)!
            while true {
                guard let ev = mpv_wait_event(h, 0.5) else { continue }
                let id = ev.pointee.event_id
                let s = self
                if id == MPV_EVENT_SHUTDOWN { break }
                if s?.stopping == true { break }
                switch id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let p = ev.pointee.data?.assumingMemoryBound(to: mpv_event_property.self),
                          p.pointee.format == MPV_FORMAT_FLAG, let d = p.pointee.data,
                          String(cString: p.pointee.name) == "pause" else { continue }
                    let running = d.assumingMemoryBound(to: Int32.self).pointee == 0
                    onMainThread { s?.runStateRemember(running); s?.runState?(running) }
                case MPV_EVENT_END_FILE:
                    guard let e = ev.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) else { continue }
                    let reason = e.pointee.reason
                    if reason == MPV_END_FILE_REASON_EOF {
                        onMainThread { s?.tornDown?(false) }
                    } else if reason == MPV_END_FILE_REASON_ERROR {
                        let text = String(cString: mpv_error_string(e.pointee.error))
                        AppLog.writeOut("[MPV] Fehler beim Abspielen: \(text)")
                        onMainThread { s?.tornDown?(true) }
                    }   // stop/quit/redirect: ended on purpose, nothing to report
                case MPV_EVENT_LOG_MESSAGE:
                    if let m = ev.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                        AppLog.writeOut("[MPV] \(String(cString: m.pointee.prefix)): "
                            + String(cString: m.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                default: break
                }
            }
            done.signal()
        }
        thread.name = "swiftly.mpv.events"
        thread.start()
    }

    // MARK: Closing

    func finish(onlyMedium: Bool = false) {
        guard let h = handle else { return }
        if onlyMedium { command(["stop"]); return }
        // Render context first (needs the GL context), then the core.
        if let glField, gtk_widget_get_realized(glField) != 0 { glRelease() }
        stopping = true
        mpv_wakeup(h)
        _ = eventDone.wait(timeout: .now() + 3)
        mpv_terminate_destroy(h)
        handle = nil
        if let wrapper { g_object_unref(wrapper); self.wrapper = nil; self.glField = nil }
    }

    // MARK: GL

    fileprivate func glCreate() {
        guard let handle, let glField, gl == nil else { return }
        let area = asGLArea(glField)
        gtk_gl_area_make_current(area)
        if let error = gtk_gl_area_get_error(area) {
            AppLog.writeOut("[MPV] GL-Fehler beim Anlegen: \(String(cString: error.pointee.message))")
            drawsWithoutGPU = true
            return
        }
        var message: UnsafePointer<CChar>?
        gl = mpvgl_new(UnsafeMutableRawPointer(handle), UnsafeMutableRawPointer(glField), &message)
        AppLog.writeOut("[MPV] Bildfläche: \(gl != nil ? "bereit" : message.map { String(cString: $0) } ?? "?"), Anzeige \(String(cString: mpvgl_display_kind()))")
    }
    fileprivate func glRelease() {
        guard let glField, gl != nil else { return }
        gtk_gl_area_make_current(asGLArea(glField))
        mpvgl_free(gl)
        gl = nil
    }
    fileprivate func glDraw() {
        beats += 1
        guard let gl else { return }
        let r = mpvgl_render(gl, glWidth, glHeight)
        if r == 0 { fetchedImages += 1 }
    }
}

// MARK: Probe (no window)

extension Player {
    /// Plays `path` without a picture for `seconds` and logs what the UI would ask for.
    /// Used by `SWIFTLY_MPV_PROBE=<file or url>`; honest about being a headless check.
    static func probe(_ path: String, seconds: Double = 6) {
        let url = path.contains("://") ? URL(string: path)! : URL(fileURLWithPath: path)
        let p = Player(headless: true)
        func pump(_ s: Double) {
            let end = Date().addingTimeInterval(s)
            while Date() < end { while g_main_context_iteration(nil, 0) != 0 {}; Thread.sleep(forTimeInterval: 0.02) }
        }
        var states: [Bool] = []
        p.runState = { states.append($0) }
        p.tornDown = { print("PROBE tornDown error=\($0)") }
        p.open(url, since: 2, buffer: .normal, paused: false, curve: nil)
        pump(2.5)
        print("PROBE pos=\(p.position) dur=\(p.duration) running=\(p.running) audio=\(p.audioTracks.map(\.name)) sub=\(p.subtitleTracks.map(\.name))")
        print("PROBE tech=\(p.techValues())")
        p.tempo = 1.5; pump(0.3); print("PROBE tempo=\(p.tempo)")
        p.volumeSet(40); pump(0.2); print("PROBE volume=\(p.double("volume") ?? -1)")
        p.setTime(p.duration / 2); pump(1.0); print("PROBE after seek pos=\(p.position)")
        p.audioDelay = Delay(milliseconds: 150); p.subtitleDelay = Delay(milliseconds: -100); pump(0.3)
        print("PROBE delays audio-delay=\(p.double("audio-delay") ?? 9) sub-delay=\(p.double("sub-delay") ?? 9)")
        p.halt(); pump(0.4); print("PROBE paused running=\(p.running) states=\(states)")
        p.play(); pump(0.4); print("PROBE resumed running=\(p.running) counters=\(String(describing: p.countValues))")
        pump(seconds - 4)
        p.finish()
        print("PROBE done")
    }
}

extension Player {
    /// Window probe (needs a display, e.g. Xvfb): plays into a GtkGLArea, resizes and
    /// toggles fullscreen while playing and logs the position around each step, so a
    /// restart on window changes would show as the position jumping back.
    static func probeWindow(_ path: String) {
        gtk_init()
        let url = path.contains("://") ? URL(string: path)! : URL(fileURLWithPath: path)
        let p = Player()
        let winWidget = gtk_window_new()!
        let win = UnsafeMutableRawPointer(winWidget).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_default_size(win, 640, 360)
        gtk_window_set_child(win, p.display)
        gtk_window_present(win)
        p.open(url, since: 0, buffer: .normal, curve: nil)
        func pump(_ s: Double) {
            // Bounded inside, too: a busy main loop must not stretch the wait (it did,
            // 2 s became 20 s on Windows and the notes were read after the end of the file).
            let end = Date().addingTimeInterval(s)
            while Date() < end { _ = g_main_context_iteration(nil, 0); Thread.sleep(forTimeInterval: 0.005) }
        }
        func note(_ t: String) { defer { fflush(nil) }; print(String(format: "PROBEGL %@ pos=%.2f frames=%d vo=%d %@", t, p.position, p.fetchedImages, p.showsImage ? 1 : 0, p.tickStatus)) }
        let hold = Double(ProcessInfo.processInfo.environment["SWIFTLY_MPV_PROBE_HALTEN"] ?? "") ?? 2
        pump(hold); note("start")
        gtk_window_set_default_size(win, 900, 500); pump(1); note("nach Groesse")
        gtk_window_fullscreen(win); pump(1.5); note("Vollbild")
        gtk_window_unfullscreen(win); pump(1.5); note("zurueck")
        p.finish(); print("PROBEGL done")
    }
}

// MARK: Look

extension SubtitleStyle {
    /// mpv's counterpart of ``vlcOptions(look:outputHeight:)``. mpv draws subtitles on
    /// a 720-line scale (`sub-font-size` 55 default), so margins are converted from the
    /// output height.
    static func mpvOptions(look: SubtitleLook, outputHeight: Int) -> [(String, String)] {
        func hex(_ rgb: Int) -> String { String(format: "#%06X", rgb) }
        let font = 55.0
        var o: [(String, String)] = [
            ("sub-font", fontFamily),
            ("sub-font-size", "55"),
            ("sub-scale", String(look.size.factor)),
            ("sub-color", hex(look.colour.rgb)),
            ("sub-border-color", "#E6000000"),
            ("sub-border-size", String(font * Double(look.outline.thickness) / 100 * 2)),
            ("sub-ass-override", look.keepFileStyle ? "no" : "force"),
        ]
        if look.shadow {
            o += [("sub-shadow-color", "#A0000000"), ("sub-shadow-offset", String(font * 0.04))]
        } else {
            o += [("sub-shadow-offset", "0")]
        }
        o.append(("sub-back-color", look.background ? "#A0000000" : "#00000000"))
        let margin = 22 + (look.position == .raised
            ? Double(SubtitleLook.raisedMargin(outputHeight: outputHeight)) * 720 / Double(max(outputHeight, 1))
            : 0)
        o.append(("sub-margin-y", String(Int(margin.rounded()))))
        return o
    }
}

// MARK: C callbacks

@inline(__always) private func asGLArea(_ w: Widget) -> UnsafeMutablePointer<GtkGLArea> {
    UnsafeMutableRawPointer(w).assumingMemoryBound(to: GtkGLArea.self)
}

nonisolated(unsafe) private let mpvRealizeCall: @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { _, d in
    guard let d else { return }
    Unmanaged<Player>.fromOpaque(d).takeUnretainedValue().glCreate()
}
nonisolated(unsafe) private let mpvUnrealizeCall: @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { _, d in
    guard let d else { return }
    Unmanaged<Player>.fromOpaque(d).takeUnretainedValue().glRelease()
}
nonisolated(unsafe) private let mpvRenderCall: @convention(c) (UnsafeMutablePointer<GtkGLArea>?, OpaquePointer?, gpointer?) -> gboolean = { _, _, d in
    guard let d else { return 1 }
    Unmanaged<Player>.fromOpaque(d).takeUnretainedValue().glDraw()
    return 1
}
nonisolated(unsafe) private let mpvSizeCall: @convention(c) (UnsafeMutablePointer<GtkGLArea>?, Int32, Int32, gpointer?) -> Void = { _, w, h, d in
    guard let d else { return }
    let p = Unmanaged<Player>.fromOpaque(d).takeUnretainedValue()
    p.glWidth = w; p.glHeight = h
}

