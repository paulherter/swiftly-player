import CGtk
import Foundation

/// **Media keys and the entry in the system panel.**
///
/// On Apple this is `MPRemoteCommandCenter` plus "Now Playing": the lock
/// screen shows title and image, and the device keys pause and skip. Linux
/// has no framework for this but a **standard**: `org.mpris.MediaPlayer2` on
/// the session bus. Every desktop environment (KDE, GNOME, Sway with
/// `playerctl`) binds its media keys to it and shows its playback tile from it.
///
/// **Two interfaces, not one.** `MediaPlayer2` describes the app itself (name,
/// whether it can be closed and raised), `MediaPlayer2.Player` the playback.
/// Registering only the second makes the app invisible: environments look for
/// the first.
///
/// **Properties do not update themselves.** D-Bus has no polling; without
/// `PropertiesChanged` the tile shows "Paused" forever. Hence
/// ``reportStatus(running:title:subtitle:dauer:)`` after every change.
///
/// `@unchecked Sendable` for the same reason as everywhere here: touched only
/// on GTK's main thread, which is also the thread GDBus calls back on.
final class MediaBar: @unchecked Sendable {

    /// What the panel triggers. Same handlers as the on-screen button.
    /// `prefetch` and `close` are MPRIS' `Raise` and `Quit`: the panel
    /// advertises `CanRaise`/`CanQuit`, so they must actually do something.
    ///
    /// `schlaeft` and `woke` are not keys but arrive the same way: on Linux
    /// from logind (`PrepareForSleep`), on Windows as `WM_POWERBROADCAST` to the
    /// window procedure of the media keys.
    enum Handle { case play, halt, toggle, finish, proceed, back,
                      prefetch, close, sleeps, woke }

    /// **`GVariantType` and `GDBusConnection` are incomplete types** and arrive
    /// in Swift as `OpaquePointer`, the same trap as `GtkOverlay` and
    /// `GtkAccessible`.
    ///
    /// **`G_VARIANT_TYPE` is a macro**, in C a plain cast from `const char*` to
    /// `const GVariantType*`. Swift has no such thing; `g_variant_type_new` makes
    /// a copy instead, which must be freed again.
    /// Creates an `{sv}` entry. The value is wrapped in a variant, as the type
    /// `a{sv}` requires.
    fileprivate static func register(_ builder: UnsafeMutablePointer<GVariantBuilder>?,
                                      _ name: String, _ value: OpaquePointer?) {
        guard let value else { return }
        g_variant_builder_add_value(builder, g_variant_new_dict_entry(
            g_variant_new_string(name), g_variant_new_variant(value)))
    }

    private static func type(_ text: String) -> OpaquePointer? {
        g_variant_type_new(text)
    }

    static func withTypePublic<E>(_ text: String,
                                     _ perform: (OpaquePointer?) -> E) -> E {
        withType(text, perform)
    }

    private static func withType<E>(_ text: String,
                                  _ perform: (OpaquePointer?) -> E) -> E {
        let t = type(text)
        defer { if let t { g_variant_type_free(t) } }
        return perform(t)
    }

    private var connection: OpaquePointer?
    private var name: guint = 0
    private var trunk: guint = 0
    private var player: guint = 0
    private let report: (Handle) -> Void

    fileprivate var running = false
    fileprivate var title = ""
    fileprivate var subtitle = ""
    fileprivate var duration: Double = 0
    fileprivate var spot: Double = 0
    /// **The image for the environment's tile.** The Mac sets
    /// `MPMediaItemPropertyArtwork` (`Sources/Shared/PlaybackHub.swift`);
    /// MPRIS has `mpris:artUrl`. Without it the tile in the system panel has no
    /// poster.
    fileprivate var image = ""

    init(report: @escaping (Handle) -> Void) {
        self.report = report
        signIn()
    }

    deinit {
        signOff()
        media_keys_sign_out()
        keysTarget = nil
    }

    fileprivate func resolve(_ grip: Handle) { report(grip) }

    /// Whether "next" has anything to do; see `CanGoNext`.
    fileprivate var hasNext = false
    func nextReport(_ yes: Bool) { hasNext = yes }

    // MARK: Registering

    private var systemBus: OpaquePointer?
    private var sleepSubscription: guint = 0

    /// **Sleep and wake, from logind.** Shortly before sleeping it sends
    /// `PrepareForSleep(true)`, after waking `PrepareForSleep(false)`, on the
    /// system bus, not the session bus. Without this a movie continued silent or
    /// not at all after waking: audio output had been renegotiated, the stream to
    /// the server had dropped, and the app knew about neither.
    private func sleepSignIn() {
        #if !os(Windows)
        var error: UnsafeMutablePointer<GError>?
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nil, &error) else {
            if let error { g_error_free(error) }
            return
        }
        systemBus = bus
        sleepSubscription = g_dbus_connection_signal_subscribe(
            bus, "org.freedesktop.login1", "org.freedesktop.login1.Manager",
            "PrepareForSleep", "/org/freedesktop/login1", nil,
            GDBusSignalFlags(rawValue: 0), sleepCall,
            Unmanaged.passUnretained(self).toOpaque(), nil)
        #endif
    }

    private func signIn() {
        sleepSignIn()
        var error: UnsafeMutablePointer<GError>?
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            // **Silent.** Without a session bus (sandboxed environment, build
            // container) there are no media keys, and that is no reason to stop the app.
            if let error { g_error_free(error) }
            return
        }
        connection = bus

        guard let node = g_dbus_node_info_new_for_xml(MediaBar.description, &error) else {
            if let error { g_error_free(error) }
            return
        }
        defer { g_dbus_node_info_unref(node) }

        var tableTop = GDBusInterfaceVTable()
        tableTop.method_call = mprisCall
        tableTop.get_property = mprisRead
        tableTop.set_property = nil

        let ich = Unmanaged.passUnretained(self).toOpaque()
        trunk = g_dbus_connection_register_object(
            bus, "/org/mpris/MediaPlayer2",
            g_dbus_node_info_lookup_interface(node, "org.mpris.MediaPlayer2"),
            &tableTop, ich, nil, nil)
        player = g_dbus_connection_register_object(
            bus, "/org/mpris/MediaPlayer2",
            g_dbus_node_info_lookup_interface(node, "org.mpris.MediaPlayer2.Player"),
            &tableTop, ich, nil, nil)

        // **The name must carry the ID.** Two versions of the same app may run
        // side by side; the suffix after the dot tells them apart.
        name = g_bus_own_name_on_connection(
            bus, "org.mpris.MediaPlayer2.swiftly",
            GBusNameOwnerFlags(rawValue: 1), nil, nil, nil, nil)   // REPLACE
    }

    private func signOff() {
        if let systemBus, sleepSubscription != 0 {
            g_dbus_connection_signal_unsubscribe(systemBus, sleepSubscription)
            sleepSubscription = 0
        }
        guard let bus = connection else { return }
        if trunk != 0 { g_dbus_connection_unregister_object(bus, trunk) }
        if player != 0 { g_dbus_connection_unregister_object(bus, player) }
        if name != 0 { g_bus_unown_name(name) }
        connection = nil
    }

    // MARK: Reporting

    /// Tells the environment what is playing. **After every change**, otherwise
    /// its tile stays stale.
    func reportStatus(running: Bool, title: String, subtitle: String,
                     duration: Double, spot: Double, image: String = "") {
        self.running = running
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.spot = spot
        self.image = image
        guard let bus = connection else { return }

        // **The convenient form is variadic and therefore unavailable here too.**
        // `g_variant_builder_add(b, "{sv}", …)` and `g_variant_new("(…)", …)` do not
        // exist in Swift; values are built individually and assembled. The value
        // in `a{sv}` is a **variant**, not the bare value; without
        // `g_variant_new_variant` the type does not match.
        let builder = MediaBar.withType("a{sv}") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(builder) }
        MediaBar.register(builder, "PlaybackStatus",
                               g_variant_new_string(status))
        MediaBar.register(builder, "Metadata", metadata())

        let empty = MediaBar.withType("as") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(empty) }

        var children: [OpaquePointer?] = [
            g_variant_new_string("org.mpris.MediaPlayer2.Player"),
            g_variant_builder_end(builder),
            g_variant_builder_end(empty)
        ]
        let content = children.withUnsafeMutableBufferPointer {
            g_variant_new_tuple($0.baseAddress, 3)
        }
        g_dbus_connection_emit_signal(bus, nil, "/org/mpris/MediaPlayer2",
                                      "org.freedesktop.DBus.Properties",
                                      "PropertiesChanged", content, nil)
    }

    /// The data the tile shows.
    /// **Without a title nothing is paused, there is just nothing.** After closing
    /// the player this used to report "Paused" with an empty title, leaving the
    /// environment's media tile with an empty line until the app quit. MPRIS has
    /// `Stopped` and the track `NoTrack` for this.
    fileprivate var status: String {
        title.isEmpty ? "Stopped" : (running ? "Playing" : "Paused")
    }

    fileprivate func metadata() -> OpaquePointer? {
        let builder = MediaBar.withType("a{sv}") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(builder) }
        guard !title.isEmpty else {
            MediaBar.register(builder, "mpris:trackid",
                                   g_variant_new_object_path("/org/mpris/MediaPlayer2/TrackList/NoTrack"))
            return g_variant_builder_end(builder)
        }
        // An ID is mandatory; without it some environments consider the entry
        // unfinished and do not show it at all.
        MediaBar.register(builder, "mpris:trackid",
                               g_variant_new_object_path("/de/paulherter/swiftly/titel"))
        MediaBar.register(builder, "mpris:length",
                               g_variant_new_int64(gint64(duration * 1_000_000)))
        MediaBar.register(builder, "xesam:title", g_variant_new_string(title))
        if !subtitle.isEmpty {
            let list = MediaBar.withType("as") { g_variant_builder_new($0) }
            defer { g_variant_builder_unref(list) }
            g_variant_builder_add_value(list, g_variant_new_string(subtitle))
            MediaBar.register(builder, "xesam:artist", g_variant_builder_end(list))
        }
        if !image.isEmpty {
            MediaBar.register(builder, "mpris:artUrl", g_variant_new_string(image))
        }
        return g_variant_builder_end(builder)
    }

    /// What is put on the bus: only what environments actually read.
    private static let description = """
    <node>
      <interface name="org.mpris.MediaPlayer2">
        <method name="Raise"/>
        <method name="Quit"/>
        <property name="CanQuit" type="b" access="read"/>
        <property name="CanRaise" type="b" access="read"/>
        <property name="HasTrackList" type="b" access="read"/>
        <property name="Identity" type="s" access="read"/>
        <property name="DesktopEntry" type="s" access="read"/>
        <property name="SupportedUriSchemes" type="as" access="read"/>
        <property name="SupportedMimeTypes" type="as" access="read"/>
      </interface>
      <interface name="org.mpris.MediaPlayer2.Player">
        <method name="Play"/>
        <method name="Pause"/>
        <method name="PlayPause"/>
        <method name="Stop"/>
        <method name="Next"/>
        <method name="Previous"/>
        <property name="PlaybackStatus" type="s" access="read"/>
        <property name="Metadata" type="a{sv}" access="read"/>
        <property name="Position" type="x" access="read"/>
        <property name="CanPlay" type="b" access="read"/>
        <property name="CanPause" type="b" access="read"/>
        <property name="CanSeek" type="b" access="read"/>
        <property name="CanControl" type="b" access="read"/>
        <property name="CanGoNext" type="b" access="read"/>
        <property name="CanGoPrevious" type="b" access="read"/>
      </interface>
    </node>
    """
}

// MARK: - The two callbacks

nonisolated(unsafe) private let mprisCall: @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, OpaquePointer?,
    OpaquePointer?, gpointer?
) -> Void = { _, _, _, _, name, _, call, data in
    guard let data, let name else { return }
    let bar = Unmanaged<MediaBar>.fromOpaque(data).takeUnretainedValue()
    switch String(cString: name) {
    case "Play":      bar.resolve(.play)
    case "Pause":     bar.resolve(.halt)
    case "PlayPause": bar.resolve(.toggle)
    case "Stop":      bar.resolve(.finish)
    case "Next":      bar.resolve(.proceed)
    case "Previous":  bar.resolve(.back)
    // "Raise" brings the window to the front, "Quit" closes it. Both used to be
    // acknowledged without doing anything while `CanRaise`/`CanQuit` reported
    // true, so a click on the tile did not raise the app.
    case "Raise":     bar.resolve(.prefetch)
    case "Quit":      bar.resolve(.close)
    default: break
    }
    if let call { g_dbus_method_invocation_return_value(call, nil) }
}

/// logind: `PrepareForSleep(b)`: true before sleeping, false after.
nonisolated(unsafe) private let sleepCall: @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, OpaquePointer?, gpointer?
) -> Void = { _, _, _, _, _, values, data in
    guard let data, let values, let value = g_variant_get_child_value(values, 0) else { return }
    let sleeps = g_variant_get_boolean(value) != 0
    g_variant_unref(value)
    Unmanaged<MediaBar>.fromOpaque(data).takeUnretainedValue()
        .resolve(sleeps ? .sleeps : .woke)
}

nonisolated(unsafe) private let mprisRead: @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?, gpointer?
) -> OpaquePointer? = { _, _, _, _, name, _, data in
    guard let data, let name else { return nil }
    let bar = Unmanaged<MediaBar>.fromOpaque(data).takeUnretainedValue()
    switch String(cString: name) {
    case "Identity":            return g_variant_new_string("Swiftly")
    case "DesktopEntry":        return g_variant_new_string("de.paulherter.swiftly")
    case "CanQuit", "CanRaise": return g_variant_new_boolean(1)
    case "HasTrackList":        return g_variant_new_boolean(0)
    case "SupportedUriSchemes", "SupportedMimeTypes":
        let empty = MediaBar.withTypePublic("as") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(empty) }
        return g_variant_builder_end(empty)
    case "PlaybackStatus":
        return g_variant_new_string(bar.status)
    case "Metadata":            return bar.metadata()
    case "Position":            return g_variant_new_int64(gint64(bar.spot * 1_000_000))
    case "CanPlay", "CanPause", "CanControl":
        return g_variant_new_boolean(1)
    // **What is not supported is not claimed.** `CanSeek` was true although
    // `Seek`/`SetPosition` are not in the description at all; a call from the
    // environment went nowhere and was still acknowledged as success. The Mac
    // has real commands there. Until they exist here, the tile reports the
    // truth.
    case "CanSeek":             return g_variant_new_boolean(0)
    // **And "next" only if there is a next episode.** The Mac sets
    // `nextTrackCommand.isEnabled = handles?.next != nil`; here it was
    // fixed true, so the system-panel button was active for a movie.
    case "CanGoNext":           return g_variant_new_boolean(bar.hasNext ? 1 : 0)
    case "CanGoPrevious":       return g_variant_new_boolean(0)
    default:                    return nil
    }
}

// MARK: - Keyboard media keys

import CMediaKeys

/// **Where the key presses go.** The callback comes from C and cannot
/// capture anything, so the link to the panel lives here.
nonisolated(unsafe) private var keysTarget: ((MediaBar.Handle) -> Void)?

private let keysCallback: @convention(c) (Int32) -> Void = { identifier in
    let grip: MediaBar.Handle
    switch identifier {
    case 1:  grip = .finish
    case 2:  grip = .proceed
    case 3:  grip = .back
    case 4:  grip = .sleeps
    case 5:  grip = .woke
    default: grip = .toggle
    }
    keysTarget?(grip)
}

extension MediaBar {

    /// Attaches the keyboard media keys to the window.
    ///
    /// **On Linux this does nothing:** ``anmelden()`` registers the app on the
    /// session bus, and the desktop environment sends the keys by itself. Windows
    /// has no such service: keys arrive as `WM_APPCOMMAND` at the foreground
    /// window, and must be registered explicitly for the background. Both need a
    /// window procedure of their own, which lives in ``CMediaKeys``.
    ///
    /// This keeps the call site free of branches: the same line on both
    /// platforms, with different effect.
    func anWindow(_ window: Widget) {
        // `GtkNative` is an interface, not a type; it arrives in Swift as
        // `OpaquePointer`, the same trap as `GtkOverlay`.
        guard let area = gtk_native_get_surface(OpaquePointer(window)) else { return }
        keysTarget = { [weak self] grip in self?.resolve(grip) }
        media_keys_sign_in(UnsafeMutableRawPointer(area), keysCallback)
    }
}
