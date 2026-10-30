import CImageBridge
import CGtk
import CVLC
import Foundation
import JellyfinKit

/// **The player.** System libVLC, not VLCKit.
///
/// Apple platforms bundle VLCKit as an XCFramework; on Linux libVLC is a system
/// library. Whether to transcode is decided the same way on every platform
/// (`DeviceProfile` in the package); only the thing that plays the file differs.
///
/// **This runs libVLC 3, Apple runs libVLC 4.** VLC 4 is not packaged on Arch,
/// and the one difference that matters favours 3: the seek bug in MKV without
/// cues is a **VLC 4 regression** and does not exist in 3. That is also why
/// `:demux=mkv_trusted` (the workaround for that bug) is not set here.
///
/// Frames arrive via ``ImageBridge`` from the C part; `imagebridge.h` explains why
/// that is not in Swift.
final class Player: @unchecked Sendable {

    private var kern: OpaquePointer?
    private var player: OpaquePointer?
    private var bridge: OpaquePointer?
    private var imageField: Widget!
    /// **The HDR picture.** A `GtkGLArea` next to the `GtkPicture`: HDR arrives as
    /// 10-bit YUV and is tone-mapped to SDR on the GPU (`hdrimage.h`). Only one of
    /// the two is visible at a time.
    private var glField: Widget!
    /// Holds the picture field and the GL field; the player page attaches this.
    private var wrapper: Widget!
    private var hdr: OpaquePointer?
    /// `HDRBILD_PQ`/`HDRBILD_HLG` for the current title, 0 on the RGB path.
    private var hdrIdLine: Int32 = 0
    private var filling = false
    /// Size of the GL framebuffer in device points, from the `resize` signal.
    fileprivate var glWidth: Int32 = 0
    fileprivate var glHeight: Int32 = 0
    private var hdrErrorReported = false
    private var tick: guint = 0

    /// **Number of frames the bridge has delivered since opening.**
    /// Diagnostics only: without it, "picture stays black" cannot be told apart
    /// from "frames arrive but are not drawn".
    private(set) var fetchedImages = 0
    /// GTK fell back to `GskCairoRenderer`; see ``rendererReport()``.
    private(set) var drawsWithoutGPU = false

    /// **How often GTK's frame clock has called the player.**
    /// If this number stops, the cause is not VLC but the picture field no longer
    /// getting a frame clock.
    private(set) var beats = 0
    #if DEBUG
    private var holdDuration = 0.0
    private var lastReported = 0
    #endif

    /// How the view shows the picture: a single `GtkPicture`.
    var display: Widget! { wrapper }

    /// Diagnostics: is the picture field attached to the window, does it have a
    /// frame clock, and is the callback registered?
    var tickStatus: String {
        guard let wrapper else { return "kein Bildfeld" }
        let mapped = gtk_widget_get_mapped(wrapper) != 0
        let clock = gtk_widget_get_frame_clock(wrapper) != nil
        let parent = gtk_widget_get_parent(wrapper) != nil
        return "mapped=\(mapped ? 1 : 0) uhr=\(clock ? 1 : 0) eltern=\(parent ? 1 : 0) id=\(tick)"
    }

    /// **VLC is playing (`true`) or paused (`false`)**, from libVLC's `Playing`/`Paused`
    /// events, on GTK's thread. Counterpart of `VLCPlayerView.runsReported` on
    /// Apple: reports what VLC does, not what a button expects.
    var runState: ((Bool) -> Void)?
    /// Stop, end or error **of the current media**, not of one that
    /// ``finish(onlyMedium:)`` stopped on purpose (its event arrives later and
    /// carries a different player). True means VLC reported an error. Main thread.
    var tornDown: ((Bool) -> Void)?

    /// Is `source` the player that is currently running?
    fileprivate func isRunning(_ source: UInt) -> Bool {
        UInt(bitPattern: player.map { UnsafeMutableRawPointer($0) }) == source
    }

    init() {
        // No VLC user interface and no windows of its own; the picture is rendered here.
        // `--no-video-title-show` suppresses the title overlay VLC otherwise draws.
        var words = ["--no-video-title-show", "--quiet"]
        // **The switch applies to every build**, not just debug: whoever reports a bug
        // runs the shipped build. With `--quiet` VLC also stays silent about
        // "no suitable decoder module", which is exactly the line missing from a
        // user's log.
        if ProcessInfo.processInfo.environment["SWIFTLY_VLC_MELDUNGEN"] == "1" {
            words = ["--no-video-title-show", "--verbose=1"]
        }
        #if DEBUG
        // **For checking whether modules are missing.** With `--quiet` VLC stays silent
        // about "no suitable decoder module"; in debug builds `SWIFTLY_VLC_MELDUNGEN=1`
        // sends errors and warnings to stderr.
        if ProcessInfo.processInfo.environment["SWIFTLY_VLC_MELDUNGEN"] == "1" {
            words = ["--no-video-title-show", "--verbose=1"]
        }
        #endif
        // **Do not drop frames early** (Apple `VLCPlayer.library`).
        // Old DVD rips stuttered: the vout drops a frame as soon as it would be late
        // by an estimate based on the maximum of filter and render time, so a single
        // timing spike costs whole frames. **Set on the library, not on the media**;
        // on the media the option demonstrably has no effect. Present in libVLC 3.0.23
        // (`vlc -H --advanced`).
        words.append("--no-drop-late-frames")
        // **Deinterlace with `bob`, also on the library** (Apple
        // `VLCPlayerView.library`). As a media option it never took effect: libVLC
        // 3.0.23 still logged "using x deinterlace method" for 1080i50, and "using bob"
        // with `--deinterlace-mode=bob`. Only applies where VLC detects interlaced fields.
        words.append("--deinterlace-mode=bob")
        words += SubtitleStyle.vlcOptions()

        #if os(Linux)
        // Tells VLC not to touch Xlib, since rendering happens here.
        // On Windows VLC does not know the option and complains.
        words.insert("--no-xlib", at: 0)
        #endif

        #if os(Windows)
        // **libVLC does not find its modules by itself.** On Linux they are at a fixed
        // system location; on Windows they sit next to the DLL, and libVLC only looks
        // there if it was loaded from its own directory. Without this hint the player
        // starts without a single decoder, and the picture stays black without any
        // error message.
        if ProcessInfo.processInfo.environment["VLC_PLUGIN_PATH"] == nil,
           let itself = Platform.programPath {
            let module = URL(fileURLWithPath: itself)
                .deletingLastPathComponent()
                .appendingPathComponent("plugins").path
            if FileManager.default.fileExists(atPath: module) {
                module.withCString { _ = g_setenv("VLC_PLUGIN_PATH", $0, 1) }
            }
        }
        #endif

        // **`libvlc_new` does not belong on the main thread.**
        //
        // It scans the module list: on Windows hundreds of DLLs in the `plugins` folder,
        // each inspected by the virus scanner on first use. A user log showed
        // `[Hauptfaden] VLC halt hat 13030 ms gebraucht` on the **first** playback,
        // where there was nothing to stop: the call touched `App.mediaPlayer`, a `lazy var`,
        // so its initializer ran at that moment and the window froze for 13 seconds.
        //
        // The core is therefore created concurrently. Anyone who wants to open earlier
        // stores a request, which runs as soon as the core exists.
        let values = words
        Task.detached { [self] in
            #if DEBUG
            // **Makes the waiting case actually happen.** On a fast machine the core is ready
            // after 0.1 s and the "title waits" branch would never run, so it would be untested.
            if let slow = ProcessInfo.processInfo.environment["SWIFTLY_VLC_LANGSAM"],
               let s = UInt64(slow) { try? await Task.sleep(nanoseconds: s * 1_000_000_000) }
            #endif
            var arguments: [UnsafePointer<CChar>?] = []
            for word in values { arguments.append(strdup(word)) }
            let done = libvlc_new(Int32(arguments.count), &arguments)
            for pointer in arguments { free(UnsafeMutableRawPointer(mutating: pointer)) }
            let address = UInt(bitPattern: done.map { UnsafeMutableRawPointer($0) })
            onMainThread {
                self.kern = address == 0 ? nil : OpaquePointer(UnsafeMutableRawPointer(bitPattern: address)!)
                if self.kern == nil {
                    // **Without a core, a title waited forever.** `open` stored it as a pending
                    // request, the request called `open`, which stored it again; the user saw the
                    // loading veil and the log said nothing.
                    self.broken = true
                    AppLog.writeOut("[Player] FEHLER: libVLC liess sich nicht starten"
                        + " (VLC_PLUGIN_PATH, fehlende Module?)")
                } else {
                    self.vlcMessagesConnect()
                    AppLog.writeOut("[Player] VLC bereit")
                }
                let waits = self.waitingJob
                self.waitingJob = nil
                waits?()
            }
        }
        bridge = image_bridge_new()
        imageField = gtk_picture_new()
        glField = gtk_gl_area_new()
        wrapper = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        hdr = hdr_image_new()
        // **The picture field outlives its page**, more precisely the wrapper holding it
        // together with the GL field. It is created once and attached to a new player
        // page on every open; when the old page is popped from the stack, the field
        // loses its parent and with it its last reference. On the second open `display`
        // would hold a freed pointer, and GObject dies on it with an address that looks
        // random. This is how the app crashed before the wrapper was retained.
        g_object_ref_sink(wrapper)
        gtk_picture_set_content_fit(OpaquePointer(imageField), GTK_CONTENT_FIT_CONTAIN)
        for inputField in [wrapper, imageField, glField] {
            gtk_widget_set_hexpand(inputField, 1)
            gtk_widget_set_vexpand(inputField, 1)
        }
        gtk_box_append(asBox(wrapper), imageField)
        gtk_widget_set_visible(glField, 0)
        // One to one in device points, even when the UI is drawn scaled; see ``Skalierung``.
        gtk_box_append(asBox(wrapper), Scaling.unwarped(glField))
        glFieldConnect()
        // **And once more as soon as the picture field is back in the window.**
        // ``open(_:since:buffer:)`` registers the frame clock, but re-parenting is not
        // guaranteed to come before it: a page built while playback is already running
        // would otherwise end up without a clock. Only if a player is running at all;
        // otherwise a clock without a picture would make GTK redraw every frame for nothing.
        signal(wrapper, "map") { [weak self] in
            guard let self, self.player != nil else { return }
            self.imageTickStart()
        }
    }

    deinit { finish() }

    // MARK: Controls

    /// **Buffer as a required argument, not a default value.**
    ///
    /// On the TV this trap has bitten: the level was set on open and forgotten on
    /// episode change, so the next episode silently played with the old one. With no
    /// default, none of the three call sites can omit it; the compiler asks.
    ///
    /// What should run as soon as ``kern`` exists: at most one, the latest wins.
    /// Whoever taps twice wants the second title.
    private var waitingJob: (() -> Void)?
    /// `libvlc_new` returned nothing. See ``init()``.
    private var broken = false
    private var waitsSince: Date?

    /// Does the core exist? The loading screen tells the viewer instead of showing
    /// a black surface.
    var ready: Bool { kern != nil }

    /// - Parameter softwareDekoder: decode without hardware right away,
    ///   ``PlaybackPlan/softwareDekoder`` (MPEG-4 Part 2, XviD/DivX).
    /// - Parameter kennlinie: PQ or HLG as reported by the server
    ///   (``Farbauskunft/kennlinie(quelle:)``), `nil` for SDR. Required for the same
    ///   reason as the buffer: a forgotten HDR flag brings back the washed-out picture.
    func open(_ url: URL, since: Double, buffer: BufferLevel, paused: Bool = false,
                 softwareDecoder: Bool = false, curve: ColorRange.IdLine?) {
        if kern == nil, broken {
            AppLog.writeOut("[Player] kein VLC, Titel kann nicht spielen")
            onMainThread { [weak self] in self?.tornDown?(true) }
            return
        }
        pausedSince = nil
        guard kern != nil else {
            AppLog.writeOut("[Player] VLC noch nicht bereit, Titel wartet")
            if waitsSince == nil { waitsSince = Date() }
            waitingJob = { [self] in
                open(url, since: since, buffer: buffer, paused: paused,
                        softwareDecoder: softwareDecoder, curve: curve)
            }
            return
        }
        // **How long the first title waited for VLC.** On the first run on a machine the
        // virus scanner inspects every module DLL; afterwards everything is in the
        // system cache. Without this number "takes longer the first time" is a claim,
        // not a measurement.
        if let since = waitsSince {
            waitsSince = nil
            AppLog.writeOut(String(format: "[Player] wartete %.1f s auf VLC",
                                     Date().timeIntervalSince(since)))
        }
        finish(onlyMedium: true)
        fetchedImages = 0
        beats = 0
        #if DEBUG
        holdDuration = 0; lastReported = 0
        #endif
        leapAt = nil
        guard let kern, let bridge else { return }
        // Behind an outpost the app fetches the stream itself: libVLC cannot send
        // custom headers (issue #4). Without headers: unchanged.
        let vlcAddress = StreamForwarder.gemeinsam.address(for: url)
        if vlcAddress != url { AppLog.writeOut("[Player] Strom über den Weiterleiter") }
        guard let medium = libvlc_media_new_location(kern, vlcAddress.absoluteString) else { return }
        // **The position as a media option, not a seek after start.** The iOS version
        // does the same (`:start-time`); a seek after start sets up the stream a second
        // time.
        if since > 1 { libvlc_media_add_option(medium, ":start-time=\(Int(since))") }
        // Deinterlacing: `--deinterlace-mode=bob` is set on the library (above,
        // `woerter`); as a media option it had no effect.

        // Rebuild at the position after wake-up, **without** starting playback if it was
        // paused before.
        if paused { libvlc_media_add_option(medium, ":start-paused") }

        // **XviD/DivX without hardware** (``Erstbild/softwareOptionsDesktop``):
        // hardware decoders accept MPEG-4 Part 2 but fail on Advanced Simple Profile
        // material; on Apple the picture froze.
        if softwareDecoder {
            for option in FirstFrame.softwareOptionsDesktop { libvlc_media_add_option(medium, option) }
        }

        // **Two network options, identical to the Apple version.**
        //
        // `prefetch-buffer-size` defaults to 16 MiB, a little over three minutes of
        // content at these bitrates. Measurements on iPhone showed the stock was *not*
        // the problem (211 seconds filled). It is selectable because a connection that
        // *fluctuates* lacks nothing in stock, but one that sometimes drops out *entirely*
        // does. The levels live in the package so the same three numbers apply here and
        // on Apple.
        //
        // `http-reconnect` recovers from a drop after a longer pause: after 25 seconds
        // paused the server cleans up the idle stream, and without the option VLC treats
        // that as end of stream and rebuilds everything. While the connection holds it
        // changes nothing.
        //
        // Both exist in the libVLC 3 used here (checked in `libprefetch_plugin.so` and
        // `libhttp_plugin.so`, not taken from the version 4 documentation).
        if !url.isFileURL {
            libvlc_media_add_option(medium, ":prefetch-buffer-size=\(buffer.prefetchKiB)")
            libvlc_media_add_option(medium, ":http-reconnect")
            // **Only from the second level.** For `normal` VLC's own default stays; setting
            // it explicitly again looks intentional and changes nothing.
            if let preRun = buffer.networkLeadMilliseconds {
                libvlc_media_add_option(medium, ":network-caching=\(preRun)")
            }
        }
        player = libvlc_media_player_new_from_media(medium)
        libvlc_media_release(medium)
        guard let player else { return }
        imageDistanceSelect(curve)
        image_bridge_append(bridge, player)
        if let events = libvlc_media_player_event_manager(player) {
            let ich = Unmanaged.passUnretained(self).toOpaque()
            libvlc_event_attach(events, libvlc_event_type_t(libvlc_MediaPlayerPlaying.rawValue),
                                runStateCall, ich)
            libvlc_event_attach(events, libvlc_event_type_t(libvlc_MediaPlayerPaused.rawValue),
                                runStateCall, ich)
            // **The remaining states are for the log only.** A user log once had no line at
            // all from the player, so there was no telling whether VLC opened, was buffering
            // or stopped with an error. Without these lines the next report is blind again.
            for condition in [libvlc_MediaPlayerOpening, libvlc_MediaPlayerBuffering,
                            libvlc_MediaPlayerStopped, libvlc_MediaPlayerEndReached,
                            libvlc_MediaPlayerEncounteredError] {
                libvlc_event_attach(events, libvlc_event_type_t(condition.rawValue),
                                    stateCall, ich)
            }
        }
        AppLog.writeOut("[Player] oeffne \(url.isFileURL ? "Datei" : "Netz")"
            + " \(url.pathExtension.isEmpty ? "ohne Endung" : url.pathExtension)"
            + ", ab \(Int(since)) s, Puffer \(buffer)"
            + (softwareDecoder ? ", Dekoder Software" : ""))
        libvlc_media_player_play(player)
        libvlc_audio_set_volume(player, volumePercent)
        imageTickStart()
        rendererReport()
    }

    /// **What GTK renders with, logged once per title.**
    ///
    /// `GskCairoRenderer` means CPU rendering: every frame is scaled to window size
    /// in software, and at 1080p25 the main thread is saturated. This explains why a
    /// window cannot be moved and why idle work no longer runs. `GskGLRenderer` or
    /// `GskNglRenderer` use the GPU.
    ///
    /// One line per title, no constant noise, and it answers a question that otherwise
    /// needs a look at the remote machine.
    /// **The user changed the UI scale** while the factor was 1 at build time: the GL
    /// area has no counterpart wrapper and would get its framebuffer at the reduced
    /// resolution. The scale is passed in here; if already set, it recomputes by itself.
    func unstretchGLArea() {
        guard Scaling.factor != 1, let wrapper, let glField,
              gtk_widget_get_parent(glField) == wrapper else { return }
        g_object_ref(glField)
        gtk_box_remove(asBox(wrapper), glField)
        gtk_box_append(asBox(wrapper), Scaling.unwarped(glField))
        g_object_unref(glField)
    }

    private func rendererReport() {
        guard let wrapper, let window = gtk_widget_get_native(wrapper),
              let drawer = gtk_native_get_renderer(window) else { return }
        let name = g_type_name_from_instance(
            unsafeBitCast(drawer, to: UnsafeMutablePointer<GTypeInstance>.self))
        let clear = name.map { String(cString: $0) } ?? "unbekannt"
        AppLog.writeOut("[Player] Zeichenwerk \(clear)")
        // **The fallback to Cairo is announced, not just recorded.**
        // If the GL/EGL context is invalid (old driver, VM, remote session), GTK draws
        // on the CPU: every video frame goes through Cairo, the window stutters, and for
        // one tester the loading veil stayed up. It is now a warning with a way to try
        // it yourself, and is shown in the tech badge (``TechBadge``).
        drawsWithoutGPU = clear.contains("Cairo")
        if drawsWithoutGPU {
            AppLog.writeOut("[Player] WARNUNG: GTK zeichnet ohne Grafikbeschleunigung (Cairo)."
                + " GL/EGL nicht verfuegbar; Probe: GSK_RENDERER=ngl oder =gl setzen")
        }
    }

    /// **VLC's own messages go into the app log.**
    ///
    /// Without this libVLC is silent (`--quiet`) or writes to stderr, which nobody
    /// finds on Windows. Only on explicit request, because VLC's lines can contain
    /// the full playback URL, which carries the Jellyfin access key. Every line is
    /// sanitized first, so a forwarded log does not leak the key.
    private func vlcMessagesConnect() {
        guard ProcessInfo.processInfo.environment["SWIFTLY_VLC_MELDUNGEN"] == "1",
              let kern else { return }
        vlc_track_on(kern, vlcLogCall)
        AppLog.writeOut("[Player] VLC-Meldungen an")
    }

    /// **Volume 0 to 100** via `libvlc_audio_set_volume`. The value is remembered and
    /// reapplied on every start: VLC only knows it once audio output exists.
    private(set) var volumePercent: Int32 = 100
    func volumeSet(_ percent: Int) {
        volumePercent = Int32(min(max(percent, 0), 100))
        guard let player else { return }
        // An earlier "mute" set by VLC itself (system key) does not stick.
        if libvlc_audio_get_mute(player) == 1 { libvlc_audio_set_mute(player, 0) }
        libvlc_audio_set_volume(player, volumePercent)
    }

    /// Once audio output exists, the remembered value applies (see above).
    func volumeCatchUp() {
        guard let player, libvlc_audio_get_volume(player) != volumePercent else { return }
        libvlc_audio_set_volume(player, volumePercent)
    }

    func play() { player.map { libvlc_media_player_set_pause($0, 0) } }
    func halt() {
        if pausedSince == nil { pausedSince = Date() }
        player.map { libvlc_media_player_set_pause($0, 1) }
    }
    func toggle() { running ? halt() : play() }

    /// **Since when paused**, for ``Pausenruecksprung`` (iOS
    /// `VLCPlayerView.pausedSince`). Set on pause, also when VLC pauses by itself;
    /// cleared as soon as playback resumes and with every new media.
    private(set) var pausedSince: Date?

    #if DEBUG
    /// For the ``Fernsteuerpult``: pretend it has been paused for `sekunden`.
    func pausedSincePreSet(_ seconds: Double) {
        pausedSince = Date().addingTimeInterval(-seconds)
    }
    #endif

    /// Updated from the playback state (``runStateCall``).
    fileprivate func runStateRemember(_ running: Bool) {
        if running { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
    }

    var running: Bool {
        guard let player else { return false }
        return libvlc_media_player_is_playing(player) != 0
    }

    /// Seconds. libVLC works in milliseconds.
    var position: Double {
        guard let player else { return 0 }
        let t = libvlc_media_player_get_time(player)
        return t > 0 ? Double(t) / 1000 : 0
    }

    var duration: Double {
        guard let player else { return 0 }
        let l = libvlc_media_player_get_length(player)
        return l > 0 ? Double(l) / 1000 : 0
    }

    var showsImage: Bool {
        guard let player else { return false }
        return libvlc_media_player_has_vout(player) > 0
    }

    var hasAudioTracks: Bool { !audioTracks.isEmpty }

    /// **Is VLC currently seeking?** `TimeAssumption.bildDa` then uses the longer
    /// 25-second deadline instead of the short one; without this the first frame
    /// counts as present before it is, and the app reports a start to the server that
    /// has not happened yet.
    var seeksToStart: Bool {
        guard let player else { return false }
        return libvlc_media_player_get_state(player) == libvlc_Buffering
    }

    func setTime(_ seconds: Double) {
        guard let player else { return }
        // **Every seek goes into the log, with the frame counter.**
        //
        // A tester reported: seeking forward gives no picture, seeking backward does.
        // Whether new frames reach the bridge after a seek decides it, and without the
        // counter next to it the question cannot be answered.
        let from = position
        AppLog.writeOut(String(format: "[Player] springe %@ auf %.0f s (von %.0f s, Bilder bisher %d)",
                                 seconds >= from ? "vor" : "zurueck", max(0, seconds), from, fetchedImages))
        leapAt = fetchedImages
        jumpSince = Date()
        libvlc_media_player_set_time(player, libvlc_time_t(max(0, seconds) * 1000))
    }

    /// Frame count at the last seek; ``Spieler`` then reports once how many were added.
    private(set) var leapAt: Int?
    private var jumpSince = Date.distantPast

    /// Frames added since the last seek, reset afterwards. `nil` if no seek is pending.
    /// **Only after one second.** The clock may tick ten milliseconds after the seek,
    /// which would log "0 frames added" even though everything is fine. The number
    /// should be information, not a trap for the next reader.
    func jumpBalance() -> Int? {
        guard let at = leapAt, Date().timeIntervalSince(jumpSince) >= 1 else { return nil }
        leapAt = nil
        return fetchedImages - at
    }

    /// Seek distances come from the settings, not from here.
    func jump(_ seconds: Double) {
        setTime(max(0, position + seconds))
    }

    // MARK: Tracks

    struct TrackSupport { let identifier: Int32; let name: String }

    var audioTracks: [TrackSupport] { tracks(libvlc_audio_get_track_description) }
    var subtitleTracks: [TrackSupport] { tracks(libvlc_video_get_spu_description) }

    private func tracks(
        _ fetch: (OpaquePointer?) -> UnsafeMutablePointer<libvlc_track_description_t>?
    ) -> [TrackSupport] {
        guard let player else { return [] }
        guard let first = fetch(player) else { return [] }
        defer { libvlc_track_description_list_release(first) }
        var list: [TrackSupport] = []
        var pointer: UnsafeMutablePointer<libvlc_track_description_t>? = first
        while let now = pointer {
            let name = now.pointee.psz_name.map { String(cString: $0) } ?? "—"
            list.append(TrackSupport(identifier: now.pointee.i_id, name: name))
            pointer = now.pointee.p_next
        }
        return list
    }

    func setAudioTrack(_ identifier: Int32) {
        player.map { libvlc_audio_set_track($0, identifier) }
    }

    func setSubtitle(_ identifier: Int32) {
        player.map { libvlc_video_set_spu($0, identifier) }
    }

    var audioTrack: Int32 { player.map { libvlc_audio_get_track($0) } ?? -1 }
    var subtitleTrack: Int32 { player.map { libvlc_video_get_spu($0) } ?? -1 }

    /// What libVLC knows about a track that the description list does not provide:
    /// codec as fourcc, language, channels.
    struct TrackDetail { let codec: UInt32; let language: String?; let channels: Int? }

    /// **Via the media, not the description list.** libVLC 3 has no
    /// `libvlc_media_player_get_track` objects like 4; the data lives on the media,
    /// matched by the same `i_id`.
    func trackDetails() -> [Int32: TrackDetail] {
        guard let player, let medium = libvlc_media_player_get_media(player) else { return [:] }
        defer { libvlc_media_release(medium) }
        var inputField: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_track_t>?>?
        let count = libvlc_media_tracks_get(medium, &inputField)
        guard count > 0, let inputField else { return [:] }
        defer { libvlc_media_tracks_release(inputField, count) }
        var details: [Int32: TrackDetail] = [:]
        for i in 0..<Int(count) {
            guard let track = inputField[i]?.pointee else { continue }
            let language = track.psz_language.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            let channels = track.i_type == libvlc_track_audio ? track.audio.map { Int($0.pointee.i_channels) } : nil
            details[track.i_id] = TrackDetail(codec: track.i_codec, language: language, channels: channels)
        }
        return details
    }

    /// **Load a subtitle file without enabling it.** Selection afterwards goes through
    /// ``setSubtitle(_:)`` like any other track.
    @discardableResult
    func subtitleFileAppend(_ address: URL) -> Bool {
        guard let player else { return false }
        let vlcAddress = StreamForwarder.gemeinsam.address(for: address)
        return libvlc_media_player_add_slave(player, libvlc_media_slave_type_subtitle,
                                             vlcAddress.absoluteString, false) == 0
    }

    /// Speed levels come from the package, not from here.
    var tempo: Float {
        get { player.map { libvlc_media_player_get_rate($0) } ?? 1 }
        set { player.map { libvlc_media_player_set_rate($0, newValue) } }
    }

    // MARK: Delay

    /// Subtitles and audio shifted against the picture; local only, SyncPlay does
    /// not see it (template: `VLCPlayerView`, delay section). The player lives as
    /// long as the app; ``App/spielerOeffnen`` sets the values per title via
    /// ``delayForNewTitle``.
    var subtitleDelay = Delay.null {
        didSet { if subtitleDelay != oldValue { delayCatchUp() } }
    }
    var audioDelay = Delay.null {
        didSet { if audioDelay != oldValue { delayCatchUp() } }
    }

    /// Before opening another title: the same series keeps the value, anything else
    /// starts at zero (`Delay.forNewTitle`).
    func delayForNewTitle(oldTitle: String, oldSeries: String?,
                                    newTitle: String, addedSeries: String?) {
        subtitleDelay = .forNewTitle(subtitleDelay, oldTitle: oldTitle,
                                                 oldSeries: oldSeries, newTitle: newTitle,
                                                 addedSeries: addedSeries)
        audioDelay = .forNewTitle(audioDelay, oldTitle: oldTitle,
                                          oldSeries: oldSeries, newTitle: newTitle,
                                          addedSeries: addedSeries)
    }

    /// **Reapply, do not set once.** Linux creates a new libVLC player per media,
    /// which starts at 0, and like VLC 4 on Apple it may ignore the value before
    /// playback. So it is set on change, on "playing" and on the player's one-second
    /// tick, whenever libVLC reads something other than intended.
    func delayCatchUp() {
        guard let player else { return }
        let text = Int(libvlc_video_get_spu_delay(player))
        let audio = Int(libvlc_audio_get_delay(player))
        if subtitleDelay.softOff(fromMicroseconds: text) {
            libvlc_video_set_spu_delay(player, Int64(subtitleDelay.microseconds))
            AppLog.writeOut("[Verzögerung] Untertitel \(subtitleDelay.milliseconds) ms"
                + " gesetzt, VLC liest \(libvlc_video_get_spu_delay(player)) µs")
        }
        if audioDelay.softOff(fromMicroseconds: audio) {
            libvlc_audio_set_delay(player, Int64(audioDelay.microseconds))
            AppLog.writeOut("[Verzögerung] Ton \(audioDelay.milliseconds) ms"
                + " gesetzt, VLC liest \(libvlc_audio_get_delay(player)) µs")
        }
    }

    // MARK: Counters

    /// **VLC's raw counters; the calculation lives in the package.**
    ///
    /// `libvlc_media_get_stats` maintains the same totals VLCKit provides on Apple;
    /// the calculation on top is in ``JellyfinKit/Zaehlwerk`` and so exists only once.
    ///
    /// The media is fetched via the player and released again:
    /// `libvlc_media_player_get_media` increments the refcount, and without the
    /// counterpart every call would leak a reference, which at a half-second
    /// interval would go unnoticed.
    var countValues: Counter.RawValues? {
        guard let player, let medium = libvlc_media_player_get_media(player) else { return nil }
        defer { libvlc_media_release(medium) }
        var s = libvlc_media_stats_t()
        guard libvlc_media_get_stats(medium, &s) != 0 else { return nil }
        // The fields are signed; negative values would be garbage and the guard against
        // that is in the package. Here values are only kept from going below zero.
        func u(_ v: Int32) -> UInt64 { v > 0 ? UInt64(v) : 0 }
        func u(_ v: UInt64) -> UInt64 { v }
        return Counter.RawValues(
            hasRead: u(s.i_read_bytes), unpacked: u(s.i_demux_read_bytes),
            shown: u(s.i_displayed_pictures), discarded: u(s.i_lost_pictures),
            tooLate: 0,
            videoBlocks: u(s.i_decoded_video), audioBlocks: u(s.i_decoded_audio),
            audioPlay: u(s.i_played_abuffers), audioLost: u(s.i_lost_abuffers),
            beschaedigt: u(s.i_demux_corrupted), jumps: u(s.i_demux_discontinuity))
    }

    // MARK: Picture

    /// **Whole picture or fill, and why this differs from Apple.**
    ///
    /// There VLCKit sets `videoFitMode` because VLC renders itself. Here VLC does not
    /// render: frames arrive via `bildbruecke` as a texture and a `GtkPicture` fits
    /// them, so `libvlc_video_set_crop_geometry` would do nothing.
    ///
    /// GTK's own mechanism is the right one: `CONTAIN` fits the whole picture and
    /// leaves bars, `COVER` fills and crops. Neither distorts; `FILL` would be exactly
    /// the stretching that should not exist on any platform. The GL area for HDR fits
    /// the same way (`hdr_image_draw`).
    func fillFrame(_ an: Bool) {
        guard let imageField else { return }
        filling = an
        gtk_picture_set_content_fit(OpaquePointer(imageField),
                                    an ? GTK_CONTENT_FIT_COVER : GTK_CONTENT_FIT_CONTAIN)
        if let glField { gtk_gl_area_queue_render(asGL(glField)) }
    }


    /// **Fetch each frame once, not more often.** GTK's frame clock ticks at the
    /// display rate; if nothing new arrived since last time, the bridge returns
    /// `false` and nothing happens.
    /// **Register anew on every open, not just the first.**
    ///
    /// The clock is attached to the picture field, which moves to the new player page
    /// with the next title. There used to be `guard tick == 0 else { return }`; as long
    /// as the widget carries its frame clock across the move that goes unnoticed, and
    /// if it does not, the field stays without one forever. That is not something to
    /// rely on, so the callback is registered fresh each time.
    ///
    /// This was not the cause of the original freeze: there the picture lost its parent
    /// entirely (see ``Spieler/playerPageBuild``), and a fresh callback does not help
    /// without a window. The line stays as one assumption less.
    private func imageTickStart() {
        if tick != 0, let wrapper {
            gtk_widget_remove_tick_callback(wrapper, tick)
            tick = 0
        }
        guard let wrapper else { return }
        tick = gtk_widget_add_tick_callback(wrapper, imageTick,
                                            Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    fileprivate func imageFetch() {
        beats += 1
        #if DEBUG
        // **For testing the watchdog itself.** `SWIFTLY_BREMSE=300` delays the main
        // thread on every frame and must trigger the clock-gap message. A watchdog that
        // never fired is not a watchdog.
        if let brake = ProcessInfo.processInfo.environment["SWIFTLY_BREMSE"],
           let ms = UInt32(brake), ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
        let begun = ContinuousClock.now
        defer {
            let d = ContinuousClock.now - begun
            holdDuration += Double(d.components.attoseconds) / 1e15   // ms
            if fetchedImages > 0, fetchedImages % 100 == 0, fetchedImages != lastReported {
                lastReported = fetchedImages
                AppLog.writeOut(String(format: "[Bild] %d Bilder, %.2f ms je Bild im Schnitt",
                                         fetchedImages, holdDuration / Double(fetchedImages)))
            }
        }
        #endif
        guard let bridge else { return }
        var state = ImageState()
        guard image_bridge_fetch(bridge, &state), state.width > 0, state.height > 0 else { return }
        fetchedImages += 1
        guard state.art == Int32(PIXEL_FORMAT_RGB24) else {
            hdrImageLoad(&state)
            return
        }
        guard let data = state.layer.0 else { return }
        let width = state.width, height = state.height, rowTick = state.tick.0

        let length = Int(rowTick) * Int(height)
        guard let bytes = g_bytes_new(data, gsize(length)) else { return }
        defer { g_bytes_unref(bytes) }
        guard let texture = gdk_memory_texture_new(Int32(width), Int32(height),
                                                  GDK_MEMORY_R8G8B8,
                                                  bytes, gsize(rowTick)) else { return }
        gtk_picture_set_paintable(OpaquePointer(imageField), texture)
        g_object_unref(UnsafeMutableRawPointer(texture))
    }

    // MARK: HDR

    /// **RGB or 10-bit YUV, decided before start for exactly this title.**
    ///
    /// On the RGB path VLC converts with swscale and leaves the transfer curve alone:
    /// PQ values shown as sRGB are the flat, pale picture a user saw next to mpv.
    /// libVLC 3 can tone-map only in its own OpenGL output, not in the raw-frame
    /// callbacks used here, so the shader in `hdrimage.c` maps HDR itself.
    ///
    /// SDR stays on the RGB path, unchanged. Without usable GL (VM, remote session)
    /// HDR does too: flat, but with a picture. `SWIFTLY_HDR=aus` forces the old path
    /// for comparison.
    private func imageDistanceSelect(_ curve: ColorRange.IdLine?) {
        guard let bridge, let imageField, let glField else { return }
        var distance: Int32 = 0
        if let curve {
            if ProcessInfo.processInfo.environment["SWIFTLY_HDR"] == "aus" {
                AppLog.writeOut("[Player] HDR (\(curve)) ohne Tonemapping: SWIFTLY_HDR=aus")
            } else if !Player.glSuitable() {
                AppLog.writeOut("[Player] HDR (\(curve)) ohne Tonemapping: kein GL")
            } else {
                distance = curve == .hlg ? Int32(HDRBILD_HLG) : Int32(HDRBILD_PQ)
                AppLog.writeOut("[Player] HDR (\(curve)): Tonemapping auf der Grafikkarte")
            }
        }
        hdrIdLine = distance
        image_bridge_hdr(bridge, distance != 0)
        gtk_widget_set_visible(glField, distance != 0 ? 1 : 0)
        gtk_widget_set_visible(imageField, distance != 0 ? 0 : 1)
    }

    /// **Can this machine run the shader at all?** Checked once per run in a separate
    /// GL context, before VLC learns the format. If that only turned out at the GL
    /// area, the title would already be running in YUV and the picture would stay black
    /// instead of merely flat.
    nonisolated(unsafe) private static var glChecked: Bool?
    private static func glSuitable() -> Bool {
        if let glChecked { return glChecked }
        var suitable = false
        defer { glChecked = suitable }
        guard let display = gdk_display_get_default() else { return false }
        var error: UnsafeMutablePointer<GError>?
        guard let context = gdk_display_create_gl_context(display, &error) else {
            glErrorReport("kein GL-Kontext", error)
            return false
        }
        defer { g_object_unref(UnsafeMutableRawPointer(context)) }
        guard gdk_gl_context_realize(context, &error) != 0 else {
            glErrorReport("GL-Kontext nicht bereit", error)
            return false
        }
        gdk_gl_context_make_current(context)
        defer { gdk_gl_context_clear_current() }
        guard let probe = hdr_image_new() else { return false }
        defer { hdr_image_free(probe) }
        suitable = hdr_image_set_up(probe, gdk_gl_context_get_use_es(context) != 0)
        if !suitable {
            AppLog.writeOut("[Player] HDR-Shader: \(String(cString: hdr_image_error(probe)))")
        }
        hdr_image_give_up(probe)
        return suitable
    }

    private static func glErrorReport(_ was: String, _ error: UnsafeMutablePointer<GError>?) {
        let reason = error.flatMap { $0.pointee.message.map { String(cString: $0) } } ?? "?"
        AppLog.writeOut("[Player] HDR: \(was) (\(reason))")
        if let error { g_error_free(error) }
    }

    private func glFieldConnect() {
        guard let glField else { return }
        let inputField = asGL(glField)
        gtk_gl_area_set_auto_render(inputField, 0)
        gtk_gl_area_set_has_depth_buffer(inputField, 0)
        let ich = Unmanaged.passUnretained(self).toOpaque()
        g_signal_connect_data(UnsafeMutableRawPointer(glField), "render",
                              unsafeBitCast(glDrawCall, to: GCallback.self), ich, nil,
                              GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(glField), "resize",
                              unsafeBitCast(glSizeCall, to: GCallback.self), ich, nil,
                              GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(glField), "unrealize",
                              unsafeBitCast(glTeardownCall, to: GCallback.self), ich, nil,
                              GConnectFlags(rawValue: 0))
    }

    /// Pushes an HDR frame into the textures. Runs on the frame clock like the RGB
    /// path; without a context (field not yet in the window) the frame is skipped.
    private func hdrImageLoad(_ state: inout ImageState) {
        guard let glField, let hdr, hdrIdLine != 0,
              gtk_widget_get_realized(glField) != 0 else { return }
        let inputField = asGL(glField)
        gtk_gl_area_make_current(inputField)
        guard gtk_gl_area_get_error(inputField) == nil,
              let context = gtk_gl_area_get_context(inputField) else { return }
        if !hdr_image_upload(hdr, &state, gdk_gl_context_get_use_es(context) != 0),
           !hdrErrorReported {
            hdrErrorReported = true
            AppLog.writeOut("[Player] HDR-Bild nicht geladen: \(String(cString: hdr_image_error(hdr)))")
        }
        gtk_gl_area_queue_render(inputField)
    }

    fileprivate func glDraw(_ context: OpaquePointer?) {
        guard let hdr else { return }
        let es = context.map { gdk_gl_context_get_use_es($0) != 0 } ?? false
        hdr_image_draw(hdr, glWidth, glHeight, filling, hdrIdLine, 0, es)
    }

    fileprivate func glFieldTearDown() {
        guard let glField, let hdr, gtk_widget_get_realized(glField) != 0 else { return }
        gtk_gl_area_make_current(asGL(glField))
        if gtk_gl_area_get_error(asGL(glField)) == nil { hdr_image_give_up(hdr) }
    }

    // MARK: Closing

    func finish(onlyMedium: Bool = false) {
        if !onlyMedium { waitingJob = nil }
        if let player {
            libvlc_media_player_stop(player)
            libvlc_media_player_release(player)
            self.player = nil
        }
        guard !onlyMedium else { return }
        if tick != 0, let wrapper {
            gtk_widget_remove_tick_callback(wrapper, tick)
            tick = 0
        }
        if let bridge { image_bridge_free(bridge); self.bridge = nil }
        if let kern { libvlc_release(kern); self.kern = nil }
        // The picture field and GL field belong to the wrapper and go with it. The GL
        // objects are freed beforehand by ``glFieldTearDown()`` (signal `unrealize`);
        // `hdr` itself no longer holds a context.
        if let wrapper {
            g_object_unref(wrapper)
            self.wrapper = nil; self.imageField = nil; self.glField = nil
        }
        if let hdr { hdr_image_free(hdr); self.hdr = nil }
    }
}

@inline(__always) private func asGL(_ w: Widget) -> UnsafeMutablePointer<GtkGLArea> {
    UnsafeMutableRawPointer(w).assumingMemoryBound(to: GtkGLArea.self)
}

/// `render` brings the context and expects a `gboolean`; true means "drawn,
/// nothing more to do".
nonisolated(unsafe) private let glDrawCall: @convention(c) (
    UnsafeMutablePointer<GtkGLArea>?, OpaquePointer?, gpointer?
) -> gboolean = { _, context, data in
    guard let data else { return 0 }
    Unmanaged<Player>.fromOpaque(data).takeUnretainedValue().glDraw(context)
    return 1
}

/// `resize` reports the framebuffer size in device points.
nonisolated(unsafe) private let glSizeCall: @convention(c) (
    UnsafeMutablePointer<GtkGLArea>?, Int32, Int32, gpointer?
) -> Void = { _, width, height, data in
    guard let data else { return }
    let mediaPlayer = Unmanaged<Player>.fromOpaque(data).takeUnretainedValue()
    mediaPlayer.glWidth = width
    mediaPlayer.glHeight = height
}

/// `unrealize`: the context goes, and the GL objects must go first.
nonisolated(unsafe) private let glTeardownCall: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, gpointer?
) -> Void = { _, data in
    guard let data else { return }
    Unmanaged<Player>.fromOpaque(data).takeUnretainedValue().glFieldTearDown()
}

/// libVLC's event arrives on VLC's own thread. **Do not call libVLC from here**
/// (that would hold VLC's event lock); only carry the address and state over to
/// GTK's thread. The player lives as long as the app.
nonisolated(unsafe) private let runStateCall: @convention(c) (
    UnsafePointer<libvlc_event_t>?, UnsafeMutableRawPointer?
) -> Void = { event, data in
    guard let event, let data else { return }
    let running = event.pointee.type == libvlc_event_type_t(libvlc_MediaPlayerPlaying.rawValue)
    let address = UInt(bitPattern: data)
    onMainThread {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let mediaPlayer = Unmanaged<Player>.fromOpaque(pointer).takeUnretainedValue()
        if running { mediaPlayer.delayCatchUp(); mediaPlayer.volumeCatchUp() }
        mediaPlayer.runStateRemember(running)
        mediaPlayer.runState?(running)
    }
}

/// **VLC's states into the log.** Like ``runStateCall`` on VLC's thread: do not
/// call libVLC here, only pass the number on.
nonisolated(unsafe) private let stateCall: @convention(c) (
    UnsafePointer<libvlc_event_t>?, UnsafeMutableRawPointer?
) -> Void = { event, data in
    guard let event else { return }
    func actualValue(_ art: libvlc_event_e) -> Bool {
        event.pointee.type == libvlc_event_type_t(art.rawValue)
    }
    let name: String
    if actualValue(libvlc_MediaPlayerOpening)               { name = "oeffnet" }
    else if actualValue(libvlc_MediaPlayerStopped)          { name = "angehalten" }
    else if actualValue(libvlc_MediaPlayerEndReached)       { name = "Ende erreicht" }
    else if actualValue(libvlc_MediaPlayerEncounteredError) { name = "FEHLER" }
    else if actualValue(libvlc_MediaPlayerBuffering)        { name = "puffert" }
    else { name = "Zustand \(event.pointee.type)" }
    // **Buffering arrives in 1% steps.** Only report the boundary values, otherwise
    // the log fills with a number that creeps up by 0.4.
    if actualValue(libvlc_MediaPlayerBuffering) {
        let state = event.pointee.u.media_player_buffering.new_cache
        guard state <= 0.1 || state >= 100 else { return }
        onMainThread { AppLog.writeOut("[Player] puffert \(Int(state)) %") }
        return
    }
    let end = actualValue(libvlc_MediaPlayerStopped) || actualValue(libvlc_MediaPlayerEndReached)
        || actualValue(libvlc_MediaPlayerEncounteredError)
    let error = actualValue(libvlc_MediaPlayerEncounteredError)
    let source = UInt(bitPattern: event.pointee.p_obj)
    let address = UInt(bitPattern: data)
    onMainThread {
        AppLog.writeOut("[Player] \(name)")
        guard end else { return }
        GuardHolder.share()
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let mediaPlayer = Unmanaged<Player>.fromOpaque(pointer).takeUnretainedValue()
        if mediaPlayer.isRunning(source) { mediaPlayer.tornDown?(error) }
    }
}

/// **VLC's own messages.** The line arrives already formatted from the C layer
/// (`vlc_track_on`), because `va_list` cannot be written as `@convention(c)` in
/// Swift. Runs on VLC's thread.
///
/// The access key is cut out before the line is stored: VLC logs the full URL on
/// open, which carries the Jellyfin key. Logs get forwarded; the key must not.
nonisolated(unsafe) private let vlcLogCall: @convention(c) (
    UnsafePointer<CChar>?
) -> Void = { row in
    guard let row else { return }
    var text = String(cString: row)
    for key in ["api_key=", "X-Emby-Token=", "ApiKey=", "Token="] {
        while let from = text.range(of: key) {
            let rest = text[from.upperBound...]
            let until = rest.firstIndex(where: { "&? \n\"".contains($0) }) ?? rest.endIndex
            text.replaceSubrange(from.lowerBound..<until, with: key + "…")
            if until == rest.endIndex { break }
        }
    }
    let done = text
    onMainThread { AppLog.writeOut("[VLC] " + done) }
}

/// GTK's frame clock. Like every C callback it carries the instance as a pointer.
nonisolated(unsafe) private let imageTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    Unmanaged<Player>.fromOpaque(data).takeUnretainedValue().imageFetch()
    return 1   // G_SOURCE_CONTINUE
}

/// **How text subtitles look**, same values as on Apple (`SubtitleStyle` in
/// `Sources/Shared/VLCPlayer.swift`, with the rationale): Inter SemiBold, white,
/// thin outline, light shadow, 78% of VLC's default size. libVLC 3 runs here;
/// `sub-margin` is omitted because VLC 3 already places text higher than VLC 4.
///
/// **VLC must find the font itself.** libVLC 3 queries fontconfig with its own
/// configuration (`FcInitLoadConfigAndFonts`), which `fonts_load` from
/// `Style.swift` does not see, so bundled fonts are not available to VLC. A small
/// configuration therefore includes the system's and adds our folder, via
/// `FONTCONFIG_FILE`. If the variable is already set, it is kept.
///
/// **On Windows** VLC finds fonts via GDI and the registry, not fontconfig, so a
/// bundled file is unreachable. Segoe UI Semibold ships with every Windows and is
/// the closest relative.
enum SubtitleStyle {
    static func vlcOptions() -> [String] {
        #if os(Windows)
        let font = "Segoe UI Semibold"
        #else
        let font = fontVLC() ? "Inter 18pt SemiBold" : "Sans"
        #endif
        return [
            "--freetype-font=\(font)",
            "--freetype-color=16777215",
            "--freetype-outline-thickness=3",
            "--freetype-outline-opacity=230",
            // No shadow: VLC draws a hard copy offset at an angle, which read as a slanted outline.
            "--freetype-shadow-opacity=0",
            "--sub-text-scale=78",
        ]
    }

    #if !os(Windows)
    private static func fontVLC() -> Bool {
        let dm = FileManager.default
        guard let folder = Platform.bundled("Fonts"),
              dm.fileExists(atPath: folder + "/Inter-SemiBold.ttf") else { return false }
        if ProcessInfo.processInfo.environment["FONTCONFIG_FILE"] != nil { return false }
        let system = "/etc/fonts/fonts.conf"
        guard dm.fileExists(atPath: system) else { return false }
        let between = URL(fileURLWithPath: String(cString: g_get_user_cache_dir()))
            .appendingPathComponent("swiftly")
        let file = between.appendingPathComponent("untertitel-fonts.conf")
        let content = """
            <?xml version="1.0"?>
            <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
            <fontconfig>
              <include ignore_missing="yes">\(system)</include>
              <dir>\(folder)</dir>
            </fontconfig>
            """
        do {
            try dm.createDirectory(at: between, withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            AppLog.writeOut("[Untertitel] fontconfig-Datei nicht geschrieben: \(error)")
            return false
        }
        file.path.withCString { _ = g_setenv("FONTCONFIG_FILE", $0, 1) }
        return true
    }
    #endif
}
