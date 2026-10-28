import CImageBridge
import CGtk
import Foundation
import CVLC
import JellyfinKit
import SupportKeyKit

/// **Swiftly on Linux.**
///
/// Sign-in, remembered session and a home screen with real posters, all on
/// the same `JellyfinClient` that iPhone, iPad, Apple TV and Mac use.
///
/// Only the UI is new here. Everything that decides something (which address
/// applies, what the server receives, when playback resumes) lives in
/// `JellyfinKit` and is the same file on all five platforms.
///
/// **`@unchecked Sendable`, for the same reason as ``Zeigerkiste``.**
///
/// Swift cannot know that GTK runs everything on a single thread, so for the
/// compiler this class is full of raw pointers that might be touched anywhere
/// at once. The guarantee holds because every access from a task returns via
/// ``onMainThread`` and so lands on that thread again. A method added here
/// that touches the UI directly from a task breaks it.
final class App: @unchecked Sendable {

    // Window and its two pages.
    var window: Widget!
    var pages: Widget!          // GtkStack
    private var loginPage: Widget!
    private var home: Widget!

    // Sign-in, two steps
    private var loginStep: Widget!     // GtkStack: server -> account
    private var serverField: Widget!
    /// "Advanced" under the address: custom headers (issue #4).
    private var loginReader: HeaderRowReader?
    private var connectButton: Widget!
    private var serverState: Widget!
    private var serverRow: Widget!
    private var versionRow: Widget!
    private var serverURL: URL?
    private var userField: Widget!
    private var passwordField: Widget!
    private var accountsRail: Widget!
    private var fastButton: Widget!
    /// The client of the server currently being signed in to.
    private var loginClient: JellyfinClient?
    private var loginButton: Widget!
    private var loginState: Widget!
    private var reportCurrent = false
    private var backButton: Widget!

    // MARK: Add another account: page state

    /// Switched to the code flow. It only starts then; otherwise every visit to
    /// the page would request a code from the server that nobody needs. Matches
    /// `perCode` on the Mac.
    var accountPerCode = false
    var accountCode = ""
    var accountError = ""
    var accountCodeRun: Task<Void, Never>?
    /// The wait for the Quick Connect approval on the sign-in page.
    private var fastRun: Task<Void, Never>?
    /// The page's widgets. **Fields of the class, not arguments across the
    /// thread boundary**: a `Widget` is a raw pointer and so not `Sendable`;
    /// it is only touched on GTK's main thread anyway.
    var accountButton: Widget!
    var accountStateField: Widget!
    var accountCodeField: Widget!

    // Home
    var section: Region = .start
    var railsStack: Widget!
    /// The selected genres, when shown as chips above the rows.
    private var genreChips: [String] = []
    /// What was last on the home screen; the remote control needs a title it
    /// can open.
    var lastStartRail: [Item] = []
    /// Set by the remote control: switches the tab of the open series page.
    var tabSelect: ((PageTab) -> Void)?
    /// The last **fully** loaded title of the open detail page. The page stack
    /// holds only the sparse list entry, which has no cast. Used only by
    /// ``Fernsteuerpult``.
    var lastFullTitle: Item?
    /// Series already fetched while hovering an episode tile; see
    /// ``seriesPrefetch(_:)``.
    var fullCache: [String: Item] = [:]
    var prefetching: Set<String> = []
    /// **Playback plans, fetched once**, for the "Direct Play" badge in the info
    /// row (``planJob(_:)``). The task is shared: badge and file excerpt
    /// wait on the same request, not on two.
    var planJobs: [String: Task<PlaybackPlan?, Never>] = [:]
    /// What is already answered, so a freshly built row shows the badge in the
    /// first frame instead of adding it later.
    var planReady: [String: PlaybackPlan] = [:]
    /// The tile the pointer is currently over (prefetch with a deadline).
    var planRequest: String?
    /// The episodes of the open season and the "Load season" chip above them.
    var seasonEpisodes: [Item] = []
    var seasonLoadButton: Widget?
    // MARK: Stream watchdog (see `Spieler.streamCheck`)
    var streamStandsSince: Date?
    var streamLastPoint: Double = -1
    var streamRead: UInt64 = 0
    var streamBufferGrew = Date()
    /// When the last seek happened; the watchdog pauses after it.
    var lastJump = Date.distantPast
    // MARK: Audio watchdog and idle inhibit (see `Spieler.audioCheck`)
    var audioLostLast: UInt64?
    var audioLossSince: Date?
    var audioNewTried = Date.distantPast
    var lastWoke = Date.distantPast
    /// How often this title's stream was rebuilt because VLC stopped midway;
    /// see ``streamTornDown(error:)``.
    var teardowns = 0
    /// The account row at the bottom of the sidebar; it carries the highlight
    /// while a subpage is open.
    private var profileRow: Widget?
    /// Switch the tab of the open series page via the stack, not by rebuilding.
    var tabShow: ((PageTab) -> Void)?
    var headerLine: Widget!

    /// The circles at the bottom of the bar. A ``GtkFixed``, because they
    /// overlap and GTK has no negative margins.
    var profileCircle: Widget!

    var client: JellyfinClient?
    var addresses: ImageAddress?
    /// Runs only at startup, then fades out.
    var startAnimation: StartAnimation?
    var startImage: Widget!

    /// Size and maximized state for the next start. **Not in fullscreen**:
    /// otherwise the screen size would be stored as the window size after a movie;
    /// the previous value stays.
    ///
    /// **Which renderer GTK draws the main window with: one log line per start.**
    ///
    /// `GskCairoRenderer` means CPU rendering. On a 4K screen every scrolled frame
    /// is eight million pixels in software. The player's line (``Player``) only
    /// appears with the first title, so a report of janky grids often comes from
    /// someone who has not played anything yet.
    ///
    /// Also logs whether a GL context can be created and with which driver, or
    /// with which error it fails. This is the same check GTK itself uses to decide
    /// whether to fall back to Cairo.
    private func characterItemReport() {
        var row = "[Start] Zeichenwerk "
        let nature = gtk_widget_get_native(window)
        if let nature, let mediaWork = gtk_native_get_renderer(nature),
           let name = g_type_name_from_instance(unsafeBitCast(mediaWork, to: UnsafeMutablePointer<GTypeInstance>.self)) {
            row += String(cString: name)
        } else {
            row += "unbekannt"
        }
        if let wish = ProcessInfo.processInfo.environment["GSK_RENDERER"] {
            row += " (GSK_RENDERER=\(wish))"
        }
        var error: UnsafeMutablePointer<GError>?
        if let display = gdk_display_get_default(), gdk_display_prepare_gl(display, &error) != 0,
           let nature, let area = gtk_native_get_surface(nature),
           let context = gdk_surface_create_gl_context(area, &error) {
            if gdk_gl_context_realize(context, &error) != 0 {
                gdk_gl_context_make_current(context)
                var large: Int32 = 0, small: Int32 = 0
                gdk_gl_context_get_version(context, &large, &small)
                let art = gdk_gl_context_get_api(context) == GDK_GL_API_GLES ? "GLES" : "GL"
                row += ", \(art) \(large).\(small): " + String(cString: hdr_image_unstretch_info())
                gdk_gl_context_clear_current()
            }
            g_object_unref(UnsafeMutableRawPointer(context))
        }
        if let f = error {
            row += ", GL nicht verfuegbar: " + String(cString: f.pointee.message)
            g_error_free(f)
        }
        AppLog.writeOut(row)
    }

    /// The first screen's area, in window units.
    private func firstScreen() -> (width: Int32, height: Int32)? {
        guard let display = gdk_display_get_default(),
              let list = gdk_display_get_monitors(display),
              g_list_model_get_n_items(list) > 0,
              let raw = g_list_model_get_item(list, 0) else { return nil }
        var area = GdkRectangle()
        gdk_monitor_get_geometry(OpaquePointer(raw), &area)
        g_object_unref(raw)
        return (area.width, area.height)
    }

    /// **Below 900 x 560 the grid no longer fits**: sidebar plus two tile
    /// columns plus margins. Same limit as on the Mac; without it the window could
    /// be dragged to postage-stamp size. In UI points (including the full scale
    /// factor), applied at startup and whenever the user changes the size.
    private func windowMinMetricSet() {
        let screen = firstScreen()
        gtk_widget_set_size_request(
            window,
            Scaling.windowMetric(Theme.windowMinWidth, atMost: screen?.width),
            Scaling.windowMetric(Theme.windowMinHeight, atMost: screen?.height))
    }

    /// **Change the UI scale without a restart.**
    ///
    /// Existing wrappers read the factor when laying out and simply recompute.
    /// Where none was created at startup (factor 1, the normal case on Linux),
    /// one is inserted now: around the window content, around the title bar and
    /// around the player's GL area. Panels are rebuilt on every open and query
    /// the factor themselves.
    func scaleSurface(_ share: Double) {
        guard Scaling.userSet(share) else { return }
        selection.surface = Scaling.userShare
        selection.secure()
        let f = asWindow(window)
        if Scaling.factor != 1 {
            if let cover = windowCover, !Scaling.isWrapped(cover) {
                g_object_ref(cover)
                gtk_window_set_child(f, nil)
                gtk_window_set_child(f, Scaling.wrapped(cover))
                g_object_unref(cover)
            }
            if let header = headerLine, !Scaling.isWrapped(header) {
                // A placeholder first: `gtk_window_set_titlebar(nil)` would remove the
                // window's own title bar entirely and rebuild it.
                g_object_ref(header)
                gtk_window_set_titlebar(f, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
                gtk_window_set_titlebar(f, Scaling.wrapped(header))
                g_object_unref(header)
            }
            mediaPlayer.unstretchGLArea()
        }
        Scaling.newLayOut()
        windowMinMetricSet()
        Theme.outsideLoad()
        AppLog.writeOut(String(format: "[Darstellung] Groesse der Oberflaeche %d %%, Faktor %.2f",
                                 locale: Locale(identifier: "en_US_POSIX"),
                                 Int((Scaling.userShare * 100).rounded()), Scaling.factor))
    }

    func windowStateRemember() {
        let f = asWindow(window)
        guard gtk_window_is_fullscreen(f) == 0 else { return }
        let maximized = gtk_window_is_maximized(f) != 0
        var width: Int32 = 0, height: Int32 = 0
        // In GTK4 the default size follows resizing but not maximizing, so this is
        // the size the window returns to.
        gtk_window_get_default_size(f, &width, &height)
        selection.windowMaximized = maximized
        // In UI points, not window units; see ``Skalierung``.
        let pointWidth = Scaling.points(width), pointHeight = Scaling.points(height)
        if pointWidth >= Scaling.minPoints(Theme.windowMinWidth),
           pointHeight >= Scaling.minPoints(Theme.windowMinHeight) {
            selection.windowWidth = pointWidth
            selection.windowHeight = pointHeight
        }
        selection.secure()
    }

    // MARK: - Setup

    func buildUp(hostApp: UnsafeMutablePointer<GtkApplication>!) {
        window = gtk_application_window_new(hostApp)
        // **What the pointer hover shows.** The panel used to read "SwiftlyLinux
        // Swiftly": the first part is the program name GLib takes from the binary,
        // the second the window title. The application name now matches the app and
        // the title carries the suffix.
        CharacterItem.setUp()
        // The Seerr connection is set up before the first view: the profile page
        // shows "Verbunden" or "Nicht verbunden" next to it.
        // **Before everything else**: behind a front proxy even the first request
        // needs the custom headers (issue #4).
        Cache.headersLoad()
        seerrLoad()
        g_set_application_name("Swiftly")
        g_set_prgname("swiftly")
        gtk_window_set_title(asWindow(window), "for Jellyfin")
        gtk_window_set_icon_name(asWindow(window), CharacterItem.identifier)
        // 1440 x 900, as in `Sources/macOS/SwiftlyApp.swift`. The minimum size below
        // is correct and stays.
        //
        // **Closing the window quits the app here, unlike on the Mac.** The Mac stays
        // loaded (`applicationShouldTerminateAfterLastWindowClosed = false`) and
        // reopens the window with Cmd-0, which is the convention where an app sits in
        // the Dock. Wayland has no Dock and no counterpart; a program without a window
        // that keeps running would be one the user cannot get rid of. **Deliberately
        // not aligned**: the platform decides, just as it decides where the window
        // buttons sit.
        // **Last closed size, otherwise the default.** The check against the screen
        // below applies to both: a stored size from a larger screen does not fit a
        // smaller one.
        let width = Scaling.windowSize(
            selection.windowWidth >= Scaling.minPoints(Theme.windowMinWidth) ? selection.windowWidth : 1440)
        let height = Scaling.windowSize(
            selection.windowHeight >= Scaling.minPoints(Theme.windowMinHeight) ? selection.windowHeight : 900)
        gtk_window_set_default_size(asWindow(window), width, height)
        if selection.windowMaximized { gtk_window_maximize(asWindow(window)) }
        // **If it does not fit, maximize.** Windows does not shrink a default size
        // that exceeds the screen: on 1280 x 800 the window ended up behind the
        // taskbar and past the right edge.
        if let screen = firstScreen(),
           screen.width < width + 40 || screen.height < height + 80 {
            gtk_window_maximize(asWindow(window))
        }
        windowMinMetricSet()

        pages = gtk_stack_new()
        // No cross-fade: the switch goes through ``switchStack``.
        gtk_stack_set_transition_type(OpaquePointer(pages), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_widget_set_vexpand(pages, 1)

        loginPage = loginBuild()
        home = homePageBuild()
        gtk_stack_add_named(OpaquePointer(pages), loginPage, "anmeldung")
        gtk_stack_add_named(OpaquePointer(pages), home, "start")

        headerLine = gtk_header_bar_new()
        gtk_window_set_titlebar(asWindow(window), Scaling.wrapped(headerLine))
        // **The pointer stays visible over the title bar while it moves.** In the
        // player, motion detection is attached to the picture (`ueber`); the title bar
        // is outside it. Leaving the picture upward used to hide the pointer
        // (`controlsHide`) and it did not return over the window buttons, so the
        // window was hard to grab during playback.
        onMotion(headerLine) { [weak self] in
            guard let self, self.runningTitle != nil, self.playerControls != nil else { return }
            self.controlsShow(through: .beside)
        }
        let content = stack(GTK_ORIENTATION_VERTICAL)
        append(content, pages)

        // **The start animation sits *over* the UI, not beside it.**
        //
        // A separate stack page does not work either: a `GtkStack` only lays out its
        // visible child, so the main view would never get a size. As an overlay the
        // question does not arise: the UI is laid out normally underneath and the
        // animation just covers it.
        //
        // **The black window had another cause**: the app crashed on the second frame
        // on a Cairo assertion, so no process was left. The handover was not broken.
        // See ``StartAnimation``.
        let cover: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(cover), content)
        // `SWIFTLY_START=0` turns it off, to measure its cost.
        if ProcessInfo.processInfo.environment["SWIFTLY_START"] != "0",
           let run = StartAnimation(done: { [weak self] in self?.startImageDistance() }) {
            startAnimation = run
            let reason = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_add_css_class(reason, "swiftly-startgrund")
            append(reason, run.display)
            startImage = reason
            gtk_overlay_add_overlay(OpaquePointer(cover), reason)
            // **It continues after this deadline at the latest, whatever the animation
            // does.** Same deadline as on Apple (3.5 s).
            //
            // `[self]`, not `[weak self]`: the app lives in a global reference until the
            // end, and a weak reference could not be captured in the nested Sendable
            // closure anyway.
            Task.detached { [self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                onMainThread { self.startAnimation?.complete() }
            }
        }
        gtk_window_set_child(asWindow(window), Scaling.wrapped(cover))
        windowCover = cover
        supportStart()

        keysSetUp()
        onProperty(UnsafeMutableRawPointer(window), "notify::fullscreened") { [weak self] in
            guard let self, self.runningTitle != nil else { return }
            self.fullscreenShow(full: gtk_window_is_fullscreen(asWindow(self.window)) != 0)
        }
        g_signal_connect_data(UnsafeMutableRawPointer(window), "close-request",
                              unsafeBitCast(closeRequested, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        // **The keyboard media keys.** Linux has no framework for them, only a
        // standard on the session bus; see ``MediaBar``.
        // `[self]`, not `[weak self]`: the app lives in a global reference, and a weak
        // reference could not be captured in the nested Sendable closure anyway.
        mediaBar = MediaBar { [self] grip in
            onMainThread { self.mediaHandle(grip) }
        }
        VLCVersion.text = String(cString: libvlc_get_version())
        // **The home screen reloads its rows when the app returns to the
        // foreground**, with a deadline so that switching back and forth does not
        // reload every time. The deadline is defined in the package, not here.
        onProperty(UnsafeMutableRawPointer(window), "notify::is-active") { [weak self] in
            guard let self, self.client != nil,
                  gtk_window_is_active(asWindow(self.window)) != 0 else { return }
            if Refresh.dueReturn(recent: self.lastLoaded,
                                                now: Date()) {
                self.homeLoad()
            }
        }
        // **The last used server is already in the field.** After signing out it was
        // empty and the address had to be typed again.
        let stored = Cache.readBundle()
        StartLevel.report("einstellungen")
        if stored == nil, let memo = Cache.rememberedServer() {
            gtk_editable_set_text(OpaquePointer(serverField), memo.serverURL.absoluteString)
            serverStateShow(memo.serverName.map { String(format: translated("Zuletzt: %@"), $0) } ?? "")
        }
        gtk_window_present(asWindow(window))
        characterItemReport()
        StartLevel.report("bereit")
        // **Create the player now, not on the first tap.**
        //
        // It is a `lazy var`; whoever touches it first pays for its constructor. On
        // the first press of "Abspielen" that was the viewer: thirteen seconds in a
        // tester's log during which the window froze. The core now loads
        // concurrently, but it still has to be triggered, and here is the right
        // moment: the window is up, and it takes seconds until someone picks a title.
        _ = mediaPlayer
        // **Only now is there a window surface.** Before that the window has no
        // counterpart in the window system, and without one the media keys cannot be
        // registered. On Linux this line does nothing; the session bus handles it.
        mediaBar?.anWindow(window)
        // The animation starts itself once its surface is attached; see
        // ``Startanimation/losfahren()``. Starting from here would be too early.

        // Remembered session: go straight to the home screen without asking.
        // **The bundle, not the single session**, otherwise only one account would
        // remain in the strip after a restart.
        if let store = stored {
            StartLevel.report("server")
            bundle = store.bundle
            sessionInSet(store.bundle.activeOne, serverName: store.serverName)
        }
    }

    /// The animation is done: the cover fades out, everything underneath has
    /// long been ready.
    private func startImageDistance() {
        guard startAnimation != nil, let image = startImage else {
            return
        }
        startAnimation = nil
        gtk_widget_set_can_target(image, 0)
        gentle(on: image, from: 1, to: 0) { gtk_widget_set_opacity(image, $0) }
        // **Disappearing must not depend on the frame clock.**
        //
        // `gentle` fades via `gtk_widget_add_tick_callback`, and that has failed to
        // fire here before. If it fails again, opacity stays at one and the black
        // cover stays: the app would start into a black window. The timer removes it
        // afterwards in every case. If the fade works, it is not visible; if not,
        // the cover is gone anyway.
        // The pointer crosses a thread boundary, so it goes into the box.
        let container = held(image)
        Task.detached {
            try? await Task.sleep(nanoseconds: 340_000_000)
            onMainThread {
                defer { letGo(container) }
                gtk_widget_set_opacity(container.widget, 0)
                gtk_widget_set_visible(container.widget, 0)
            }
        }
        // **The cover stays attached instead of being removed.** Removing a widget
        // while its tick callback is still pending is the fourth trap. Invisible and
        // without hit testing it costs nothing, and the animation frees its memory
        // itself once the callback unregisters.
    }

    // MARK: - Sign-in

    private func loginBuild() -> Widget! {
        // **Two steps, as on all other platforms.** First the address and connect,
        // then the account. The Mac drives this with `AppModel.Phase` (disconnected,
        // needsLogin(serverName:version:), ready), and the same order applies here.
        // A separate flow per platform would be exactly the kind of deviation to avoid:
        // input method and window size may differ, the path may not.
        loginStep = gtk_stack_new()
        gtk_stack_set_transition_type(OpaquePointer(loginStep),
                                      GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT)
        gtk_stack_add_named(OpaquePointer(loginStep), serverStepBuild(), "server")
        gtk_stack_add_named(OpaquePointer(loginStep), accountStepBuild(), "konto")
        return loginStep
    }

    /// Step one: where is the server?
    ///
    /// **The spacings are copied, not estimated.** They appear in
    /// `Sources/macOS/RootView.swift` as `.padding(.top, ...)` at exactly these
    /// places: logo, 40 gap, question, 24, field, 24, button. A `GtkBox` with a
    /// uniform spacing would make them all equal, so each child gets its own top
    /// margin here.
    private func serverStepBuild() -> Widget! {
        let center = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(center, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(center, GTK_ALIGN_CENTER)

        append(center, Theme.wordmark(height: 44))

        let question = label(translated("Wo steht dein Jellyfin-Server?"),
                                 style: "swiftly-koerper")
        gtk_widget_add_css_class(question, "dim-label")
        gtk_widget_set_margin_top(question, 40)
        append(center, question)

        // The globe in the field; on the Mac that is `Image("globe")`.
        serverField = inputRow(symbol: "network-server-symbolic", placeholder: "tv.beispiel.de")
        gtk_widget_set_margin_top(serverField, 24)
        append(center, serverField)

        let (advanced, reader) = advancedBuild(available: [])
        gtk_widget_set_size_request(advanced, Int32(Theme.loginWidth), -1)
        gtk_widget_set_halign(advanced, GTK_ALIGN_CENTER)
        loginReader = reader
        append(center, advanced)

        serverState = reportRow()
        append(center, serverState)

        connectButton = primaryButton(translated("Verbinden"))
        gtk_widget_set_margin_top(connectButton, 24)
        gtk_widget_set_sensitive(connectButton, 0)
        append(center, connectButton)

        signal(connectButton, "clicked") { [weak self] in self?.linkUp() }
        signal(serverField, "activate") { [weak self] in self?.linkUp() }
        // The Mac disables the button while the field is empty
        // (`.disabled(address.isEmpty)`). Same here, except GTK has to be asked on
        // every change instead of once on evaluation.
        signal(serverField, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(self.connectButton,
                                     self.text(self.serverField).isEmpty ? 0 : 1)
        }
        return center
    }

    /// Step two: which account?
    ///
    /// Logo, 34, server name, 4, version, 28, user, 10, password, 24, button;
    /// taken from `SignInView` on the Mac.
    /// Fetches the public accounts and checks whether the server offers Quick
    /// Connect. Both are server information, not settings.
    private func accountsFetch(_ c: JellyfinClient) {
        loginClient = c
        Task.detached { [self] in
            // Separate tasks instead of `async let`; see ``nebenher(_:)``.
            let accounts = besideFrom { try? await c.publicUser() }
            let fast = besideFrom { await c.quickConnectAddBar() }
            let list = await accounts.value ?? []
            let possible = await fast.value
            // **Fetch the address before the main thread.** `userImage` belongs to
            // the client actor; building the tile would access it from outside.
            var collected: [(PublicUser, URL?)] = []
            for user in list.prefix(6) {
                collected.append((user, await c.userImage(user, border: 128)))
            }
            let images = collected
            onMainThread {
                gtk_widget_set_visible(self.fastButton, possible ? 1 : 0)
                wipe(self.accountsRail)
                gtk_widget_set_visible(self.accountsRail, list.isEmpty ? 0 : 1)
                for (user, image) in images {
                    append(self.accountsRail, self.accountsTile(user, image: image))
                }
                // **With exactly one account the name is already filled in.** Only the
                // password is missing then.
                if list.count == 1 {
                    gtk_editable_set_text(OpaquePointer(self.userField), list[0].name)
                }
            }
        }
    }

    /// One account as a picture with its name below.
    private func accountsTile(_ user: PublicUser,
                              image url: URL?) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-kachel")
        let pillar = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
        let (cage, image) = framedImage(width: 64, height: 64, style: "swiftly-rund")
        if let url {
            imageLoad(image, url: url, key: "konto-\(user.id)", immediate: true)
        } else {
            characterPut(cage, series: false)
        }
        append(pillar, cage)
        let name = label(user.name, style: "swiftly-zweitzeile")
        gtk_widget_set_halign(name, GTK_ALIGN_CENTER)
        append(pillar, name)
        gtk_button_set_child(asButton(button), pillar)
        signal(button, "clicked") { [weak self] in
            guard let self else { return }
            gtk_editable_set_text(OpaquePointer(self.userField), user.name)
            gtk_widget_grab_focus(self.passwordField)
        }
        return button
    }

    /// **Sign in with a code, without a password.**
    ///
    /// The server gives a six-digit code; whoever approves it on an already
    /// signed-in device signs this one in. The flow runs until approved or
    /// cancelled.
    private func fastLogin() {
        guard let c = loginClient else { return }
        fastRun?.cancel()
        // **Held, and cancelled on leaving** (back, sign out, other sign-in).
        // Previously a `Task.detached` kept running for five minutes, and a late
        // approval signed the user in unexpectedly.
        fastRun = Task.detached { [self] in
            let preGait: LoginCode
            do { preGait = try await c.quickConnectStart() } catch {
                // Name the reason, e.g. "Quick Connect abgeschaltet", rather than a generic
                // "no code".
                if Task.isCancelled { return }
                let text = readableError(error)
                onMainThread { self.loginStateShow(text) }
                return
            }
            if Task.isCancelled { return }
            onMainThread {
                self.loginStateShow(String(format: translated("Code %@ — auf einem angemeldeten Gerät freigeben"), preGait.code))
            }
            // Deadline, interval and handling of network errors: ``Quickconnectwarten``
            // in the package, as on Apple and Android.
            for await event in c.quickConnectWait(preGait) {
                if Task.isCancelled { return }
                switch event {
                case .rest: continue
                case let .end(last):
                    let text = QuickConnectDeadline.endText(last: last)
                    onMainThread { self.loginStateShow(text) }
                    return
                case .released:
                    do {
                        let session = try await c.signInWithQuickConnect(preGait)
                        if Task.isCancelled { return }
                        onMainThread {
                            // Address, name and ID are now all in the session itself; `serverURL` is no
                            // longer needed here.
                            let serverName = gtk_label_get_text(OpaquePointer(self.serverRow))
                                .map { String(cString: $0) }
                            self.loginStateShow("")
                            self.sessionRecord(session, serverName: serverName)
                        }
                    } catch {
                        let text = readableError(error)
                        onMainThread { self.loginStateShow(text) }
                    }
                    return
                }
            }
        }
    }

    private func accountStepBuild() -> Widget! {
        let center = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(center, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(center, GTK_ALIGN_CENTER)

        append(center, Theme.wordmark(height: 44))

        serverRow = label("", style: "swiftly-titel")
        gtk_widget_set_margin_top(serverRow, 34)
        append(center, serverRow)

        versionRow = label("", style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(versionRow, "swiftly-leise")
        gtk_widget_set_margin_top(versionRow, 4)
        append(center, versionRow)

        // **"Who is watching?"**: the server's public accounts, with pictures.
        // The Mac fetches them and preselects the name when there is exactly one
        // (`Shared/RootView.swift`); here there was only an empty text field in which
        // the name had to be typed exactly.
        accountsRail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        gtk_widget_set_halign(accountsRail, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(accountsRail, 26)
        gtk_widget_set_visible(accountsRail, 0)
        append(center, accountsRail)

        userField = inputRow(symbol: "avatar-default-symbolic",
                                    placeholder: translated("Benutzername"))
        gtk_widget_set_margin_top(userField, 28)
        append(center, userField)

        passwordField = inputRow(symbol: "channel-secure-symbolic",
                                    placeholder: translated("Passwort"), secret: true)
        gtk_widget_set_margin_top(passwordField, 10)
        append(center, passwordField)

        loginState = reportRow()
        append(center, loginState)

        loginButton = primaryButton(translated("Anmelden"))
        gtk_widget_set_margin_top(loginButton, 24)
        gtk_widget_set_sensitive(loginButton, 0)
        append(center, loginButton)

        // The Mac returns via the window buttons; here the UI needs a way back,
        // otherwise the user is stuck on the wrong server.
        // **Quick Connect as a sign-in method.** Until now this page could only do the
        // opposite direction (approving someone else's code). Signing in without
        // typing a password was not possible.
        fastButton = gtk_button_new_with_label(translated("Mit Code anmelden"))
        gtk_widget_add_css_class(fastButton, "swiftly-flach")
        gtk_widget_set_margin_top(fastButton, 10)
        gtk_widget_set_halign(fastButton, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(fastButton, 0)
        signal(fastButton, "clicked") { [weak self] in self?.fastLogin() }
        append(center, fastButton)

        backButton = gtk_button_new_with_label(translated("Anderer Server"))
        gtk_widget_add_css_class(backButton, "swiftly-flach")
        gtk_widget_set_margin_top(backButton, 14)
        gtk_widget_set_halign(backButton, GTK_ALIGN_CENTER)
        append(center, backButton)

        signal(loginButton, "clicked") { [weak self] in self?.signIn() }
        signal(passwordField, "activate") { [weak self] in self?.signIn() }
        signal(userField, "activate") { [weak self] in
            guard let self else { return }
            gtk_widget_grab_focus(self.passwordField)
        }
        signal(userField, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(self.loginButton,
                                     self.text(self.userField).isEmpty ? 0 : 1)
        }
        signal(backButton, "clicked") { [weak self] in
            guard let self else { return }
            self.fastRun?.cancel()
            self.fastRun = nil
            gtk_stack_set_visible_child_name(OpaquePointer(self.loginStep), "server")
        }
        return center
    }

    /// The error line below the fields: 12-point text in `warning`, centered,
    /// wrapping at block width. It is always present and empty while nothing is
    /// wrong, otherwise the button would jump down on the first error.
    private func reportRow() -> Widget! {
        let l = label("", style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(l, "swiftly-warnung")
        gtk_widget_set_size_request(l, Int32(Theme.loginWidth), -1)
        gtk_widget_set_margin_top(l, 12)
        gtk_widget_set_visible(l, 0)
        return l
    }

    func text(_ inputField: Widget!) -> String {
        gtk_editable_get_text(OpaquePointer(inputField)).map { String(cString: $0) } ?? ""
    }

    /// **An empty label is not zero tall.** GTK still gives it a line, and with
    /// the top margin the button would sit 29 points too low permanently. On the
    /// Mac the error block only appears when there is an error. So show and hide
    /// instead of clearing the text.
    private func message(_ row: Widget!, _ s: String) {
        gtk_label_set_text(OpaquePointer(row), s)
        gtk_widget_set_visible(row, s.isEmpty ? 0 : 1)
    }

    private func serverStateShow(_ s: String) { message(serverState, s) }

    private func loginStateShow(_ s: String) { message(loginState, s) }

    // MARK: Step one: connect

    private func linkUp() {
        guard !reportCurrent else { return }
        let typedInput = text(serverField).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedInput.isEmpty else { serverStateShow(translated("Trag erst eine Adresse ein.")); return }

        // Same rule as everywhere: an address without a scheme gets `https`
        // prepended, unless it looks like a home network.
        guard let url = AppModelURLNormalizer.normalize(typedInput) else {
            serverStateShow(translated("Mit dieser Adresse kann ich nichts anfangen."))
            return
        }

        reportCurrent = true
        gtk_widget_set_sensitive(connectButton, 0)
        gtk_button_set_label(asButton(connectButton), translated("Verbinde…"))
        serverStateShow(String(format: translated("Frage %@ …"), url.absoluteString))
        // Empty means: whatever is already stored for this address stays.
        let headers = loginReader?.headers() ?? []
        let before = OwnHeaders.registered(for: url)
        if !headers.isEmpty { OwnHeaders.setDown(headers, for: url) }

        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Device.identifier,
                                   deviceName: Device.name,
                                   clientVersion: Device.version)
            do {
                // Short deadline as on Apple; see `AddressCheck`.
                let info = try await c.checkReachability()
                // Store only now: an address that does not answer leaves nothing behind.
                if !headers.isEmpty { Cache.headersSafe(headers, for: url) }
                let name = info.serverName ?? url.host() ?? translated("Server")
                let version = info.version ?? "?"
                onMainThread {
                    self.connectReady()
                    // **The response belongs to the address that was asked.** If a different
                    // one is in the field by now, it is dropped, otherwise the flow would go on
                    // with the old server.
                    guard self.text(self.serverField)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == typedInput else { return }
                    self.serverURL = url
                    // **It was fetched and thrown away.** `serverVersion` was used in the
                    // settings and the profile but was always empty because nothing ever set it.
                    self.serverVersion = version
                    Cache.serverRemember(.init(serverURL: url, serverName: name,
                                                version: version))
                    gtk_label_set_text(OpaquePointer(self.serverRow), name)
                    gtk_label_set_text(OpaquePointer(self.versionRow), "Jellyfin \(version)")
                    self.serverStateShow("")
                    gtk_stack_set_visible_child_name(OpaquePointer(self.loginStep), "konto")
                    gtk_widget_grab_focus(self.userField)
                    self.accountsFetch(c)
                }
            } catch {
                if !headers.isEmpty { OwnHeaders.setDown(before, for: url) }
                onMainThread {
                    self.connectReady()
                    guard self.text(self.serverField)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == typedInput else { return }
                    self.serverStateShow(readableError(error))
                }
            }
        }
    }

    private func connectReady() {
        reportCurrent = false
        gtk_widget_set_sensitive(connectButton, 1)
        gtk_button_set_label(asButton(connectButton), translated("Verbinden"))
    }

    // MARK: Step two: sign in

    private func signIn() {
        guard !reportCurrent, let url = serverURL else { return }
        let user = text(userField).trimmingCharacters(in: .whitespacesAndNewlines)
        let password = text(passwordField)
        guard !user.isEmpty else { loginStateShow(translated("Trag einen Benutzernamen ein.")); return }

        reportCurrent = true
        gtk_widget_set_sensitive(loginButton, 0)
        gtk_button_set_label(asButton(loginButton), translated("Melde an …"))
        loginStateShow("")

        let serverName = gtk_label_get_text(OpaquePointer(serverRow)).map { String(cString: $0) }

        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Device.identifier,
                                   deviceName: Device.name,
                                   clientVersion: Device.version)
            do {
                let session = try await c.authenticate(username: user, password: password)
                onMainThread {
                    self.loginReady()
                    gtk_editable_set_text(OpaquePointer(self.passwordField), "")
                    // ``sessionRecord(_:serverName:)`` handles saving itself; it has to know
                    // the bundle before anything is written to disk.
                    self.sessionRecord(session, serverName: serverName)
                }
            } catch {
                onMainThread {
                    self.loginReady()
                    self.loginStateShow(readableError(error))
                }
            }
        }
    }

    private func loginReady() {
        reportCurrent = false
        gtk_widget_set_sensitive(loginButton, 1)
        gtk_button_set_label(asButton(loginButton), translated("Anmelden"))
    }

    // MARK: - Multiple accounts on the same server

    /// This server's accounts and which one is active.
    ///
    /// **The bundle lives here, not in the view.** All rules attached to it (same
    /// account twice, which one applies after removal, an old single session) are
    /// in ``Kontenbund`` in the package, covered by 14 tests. Only what Linux
    /// exposes of it is here.
    var bundle: AccountBundle?

    /// Increments on every switch. Code that has to check on redraw whether its
    /// data still belongs to the signed-in account compares this value.
    ///
    /// **On Apple an `onChange` hangs on it.** That does not exist here: the UI is
    /// imperative, so ``cleanUpPostSwitch()`` is called directly for whatever
    /// needs to reload. The counter stays anyway: a task started before the switch
    /// that returns afterwards uses it to see its answer belongs to the previous
    /// account.
    var accountSwitch = 0

    /// One guard per library grid that unloads content scrolled far away.
    var tileGuard: [UnsafeMutableRawPointer: TileImageGuard] = [:]

    /// Accepts a fresh session after sign-in or Quick Connect.
    ///
    /// Returns whether it was an **account switch**, i.e. whether someone was
    /// already signed in. Matches `AppModel.sessionAdopt(_:)`.
    @discardableResult
    func sessionRecord(_ session: Session, serverName: String?) -> Bool {
        // **Whether it was a switch is decided by the package**, not this page. Both
        // platforms used to derive it from `bundle != nil`, so the rule that another
        // server is *not* a switch but a fresh start existed twice.
        // Signed in is signed in: a still-waiting code must not sign in a second time.
        fastRun?.cancel()
        fastRun = nil
        let (newer, wasSignedIn) = AccountBundle.record(session, in: bundle)
        if wasSignedIn { playerPreSwitch() }
        bundle = newer
        saveBundle(serverName: serverName)
        if wasSignedIn { cleanUpPostSwitch() }
        sessionInSet(session, serverName: serverName)
        return wasSignedIn
    }

    /// Switch to another account on the same server.
    ///
    /// **No new password.** Both credentials are in `konten.json`; the switch only
    /// changes which one applies.
    /// **The identifier is the `accountKey`, not the `userID`.** Once two
    /// servers are in the bundle, the same user ID can occur on both; comparing
    /// `userID` would hit the wrong account or none. `AccountBundle.account(_:)` checks
    /// the full key first and falls back to the user ID only as a safety net, so
    /// older callers stay readable.
    func switchAccount(toward identifier: String, inProfileRemain: Bool = true) {
        guard var new = bundle, new.activeId != identifier,
              new.account(identifier) != nil else { return }
        playerPreSwitch()
        new.switchTo(toward: identifier)
        bundle = new
        let name = serverName.isEmpty ? nil : serverName
        // **Whoever switches in the profile stays in the profile**, as on the Mac.
        // Ring and dot visibly move to the other circle, and that is the feedback the
        // design is about: "connected is what carries the accent ring and dot, and that
        // changes on click". Throwing the user to the home screen would hide the
        // answer to their own click.
        // The flight (``accountSwitchWithTransition``) instead leads to the section's page,
        // as on the iPhone.
        let wasProfile = inProfileRemain && openSubpage == .profile
        saveBundle(serverName: name)
        cleanUpPostSwitch()
        sessionInSet(new.activeOne, serverName: name)
        // **Only afterwards.** The page reads `userIdentifier` and `addresses`, which
        // ``sessionInSet(_:serverName:)`` sets; built earlier it showed the name of
        // the account just left.
        if wasProfile { subpageOpen(.profile, push: .without) }
    }

    /// **A running player closes before every account switch**, including sign-out
    /// and a new sign-in over an existing account.
    ///
    /// Otherwise it keeps running with the previous account's title and credential
    /// while the UI already shows the new one, and its progress reports go through
    /// the swapped client to an account that may not contain the title. Must come
    /// **before** the swap: ``playerClose(report:windowBack:)`` grabs
    /// client and user ID immediately, so the stop still goes to the old account.
    private func playerPreSwitch() {
        guard runningTitle != nil else { return }
        AppLog.writeOut("[Konto] Wechsel bei offenem Player, erst schliessen")
        playerClose()
    }

    /// What has to be redone after every account switch, apart from the client.
    ///
    /// **No sign-out here.** `signOff()` sends `Sessions/Logout` and revokes the
    /// credential: right for signing out, disastrous for switching, since the
    /// account being left would become unusable and the way back would end in
    /// "sign-in rejected". The old client is simply dropped.
    ///
    /// **And the rows are not cleared.** On Apple that cost two rounds: clearing
    /// first and loading later detaches every tile, and `AsyncImage` then cancels
    /// its fetch. Here ``railsShow(_:)`` replaces rows only once the new ones
    /// are there, so this function does not touch the row stack at all.
    private func cleanUpPostSwitch() {
        accountSwitch += 1
        // **Remote control belongs here, and it is not obvious.** Otherwise it keeps
        // running with the previous account's credential, and the iPhone would see the
        // Linux session under the wrong name.
        Task.detached { [remoteControl] in await remoteControl?.finish() }
        remoteControl = nil
        takeoverRun?.cancel()
        takeoverRun = nil
        takeoverOfferings = []
        // Leave the group, along with the previous account's strip and offers.
        sharedEnd()
        // Detail pages and loaded sections belong to the previous account. Without
        // this, movies and series kept showing the previous account's titles after
        // a switch: `loaded` was only cleared on sign-out, and a section loads
        // exactly once.
        pagesStack.removeAll()
        loaded.removeAll()
        openSubpage = nil
        // **And an open library page.** It shows a collection of the previous
        // account; on the Mac `LibraryView` resets it to `nil` on an account
        // switch. Here it was only cleared on a section change, so the other
        // account's collection stayed visible.
        openCollection = nil
        offeringWaiting = []
        // **Remove old content immediately** (Mac `accountSwitchFade`): the grids
        // of movies, series, watchlist and genre, the home rows and the search belong
        // to the previous account. Whatever is off-screen would otherwise briefly show
        // the old state on return before the new one arrives. New content arrives
        // staggered (``gridResponse``).
        for was in Array(gridField.keys) {
            gridJob[was, default: 0] += 1
            gridLoads.remove(was)
            gridLoaderShow(was, false)
            gridItems[was] = []
            gridSource[was] = nil
            gridFilter[was] = nil
            gridRaw[was] = nil
            if let grid = gridField[was] { gridFill(grid, []) }
            if let figure = numberField[was] { gtk_widget_set_visible(figure, 0) }
            if let inputField = emptyField[was] { wipe(inputField); gtk_widget_set_visible(inputField, 0) }
            gridSeasons.insert(was)
        }
        if let r = railsStack { wipe(r) }
        discardSearchResults()
        // Collections and shares belong to the previous account.
        collectionDirectory = nil
        playlistDirectory = nil
        libraryShares = [:]
        offeringFor = nil
        // **The section stays, the stack goes.** Switching from "Filme" leaves the
        // user on the root of "Filme", not on the home screen: the stack belonged to
        // the previous account, the section did not.
        //
        // **It counts as loaded here although nothing is loaded.** ``show(_:)``
        // would otherwise call ``homeLoad()`` right here, with the **old**
        // client, since the new one is only ready after `setSession`. Two loads would
        // race, and the server's response time would decide the winner. Loading
        // happens in ``sessionInSet(_:serverName:)`` with the right client.
        loaded.insert(section)
        show(section)
        loaded.removeAll()
    }

    // MARK: Add another account

    /// Signs in another account with name and password.
    ///
    /// **The page closes itself, but only on success.** On an error it stays and
    /// shows it; closing it here would swallow the message.
    /// **Does a Jellyfin answer there?**
    ///
    /// `/System/Info/Public` needs no sign-in and is the same endpoint the first
    /// sign-in uses. Only once it answers is there a form; otherwise name and
    /// password would be typed for an address that does not exist.
    func serverCheck(_ typedInput: String) {
        let raw = typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = AppModelURLNormalizer.normalize(raw) else {
            serverOnboardingErrorShow(translated("Diese Adresse ergibt keinen Server."))
            return
        }
        gtk_widget_set_sensitive(serverOnboardingButton, 0)
        primaryButtonLabel(serverOnboardingButton, translated("Prüfe …"))
        let headers = serverOnboardingHeaders
        serverOnboardingHeaders = []
        let before = OwnHeaders.registered(for: url)
        if !headers.isEmpty { OwnHeaders.setDown(headers, for: url) }
        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Device.identifier,
                                   deviceName: Device.name, clientVersion: Device.version)
            do {
                let inquiry = try await c.checkReachability()
                if !headers.isEmpty { Cache.headersSafe(headers, for: url) }
                onMainThread {
                    self.serverOnboardingURL = url
                    var pieces: [String] = []
                    if let n = inquiry.serverName, !n.isEmpty { pieces.append(n) }
                    if let v = inquiry.version, !v.isEmpty { pieces.append("Jellyfin \(v)") }
                    if pieces.isEmpty { pieces.append(url.host() ?? url.absoluteString) }
                    self.serverOnboardingChecked = pieces.joined(separator: " · ")
                    self.serverOnboardingError = ""
                    self.subpageOpen(.serverOnboarding, push: .without)
                }
            } catch {
                if !headers.isEmpty { OwnHeaders.setDown(before, for: url) }
                onMainThread {
                    gtk_widget_set_sensitive(self.serverOnboardingButton, 1)
                    primaryButtonLabel(self.serverOnboardingButton, translated("Weiter"))
                    self.serverOnboardingErrorShow(readableError(error))
                }
            }
        }
    }

    func serverOnboardingErrorShow(_ text: String) {
        serverOnboardingError = text
        guard serverOnboardingState != nil else { return }
        gtk_label_set_text(OpaquePointer(serverOnboardingState), text)
        gtk_widget_set_visible(serverOnboardingState, text.isEmpty ? 0 : 1)
    }

    /// Sign-in to a **different** server than the connected one.
    ///
    /// **`sessionRecord` already handles this.** `AccountBundle.record` no
    /// longer checks whether the session belongs to the same server: a bundle can
    /// hold any number. Nothing special is needed here except the address itself.
    func atNewServerSignIn(user: String, password: String) {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = serverOnboardingURL else { return }
        gtk_widget_set_sensitive(serverOnboardingButton, 0)
        primaryButtonLabel(serverOnboardingButton, translated("Melde an …"))
        serverOnboardingErrorShow("")
        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Device.identifier,
                                   deviceName: Device.name, clientVersion: Device.version)
            do {
                let session = try await c.authenticate(username: name, password: password)
                let inquiry = try? await c.publicSystemInfo()
                onMainThread {
                    self.serverOnboardingError = ""
                    self.accountPerCode = false
                    self.sessionRecord(session, serverName: inquiry?.serverName)
                    self.subpageOpen(.profile, push: .without)
                }
            } catch {
                onMainThread {
                    gtk_widget_set_sensitive(self.serverOnboardingButton, 1)
                    primaryButtonLabel(self.serverOnboardingButton, translated("Anmelden"))
                    self.serverOnboardingErrorShow(readableError(error))
                }
            }
        }
    }

    func accountSignIn(user: String, password: String) {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = bundle?.serverURL else { return }
        gtk_widget_set_sensitive(accountButton, 0)
        primaryButtonLabel(accountButton, translated("Melde an …"))
        gtk_widget_set_visible(accountStateField, 0)

        let serverName = self.serverName.isEmpty ? nil : self.serverName
        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Device.identifier,
                                   deviceName: Device.name,
                                   clientVersion: Device.version)
            do {
                let session = try await c.authenticate(username: name, password: password)
                onMainThread {
                    self.accountError = ""
                    self.accountPerCode = false
                    self.sessionRecord(session, serverName: serverName)
                    // Back to the profile, where the strip shows the new account with ring and
                    // dot. That is the answer to "Add".
                    self.subpageOpen(.profile, push: .without)
                }
            } catch {
                onMainThread {
                    gtk_widget_set_sensitive(self.accountButton, 1)
                    primaryButtonLabel(self.accountButton, translated("Hinzufügen"))
                    self.accountErrorShow(readableError(error))
                }
            }
        }
    }

    /// Fetches a Quick Connect code and waits until it is approved.
    func accountCodeFetch() {
        guard let url = bundle?.serverURL else { return }
        let serverName = self.serverName.isEmpty ? nil : self.serverName
        accountCodeRun = Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Device.identifier,
                                   deviceName: Device.name,
                                   clientVersion: Device.version)
            let preGait: LoginCode
            do { preGait = try await c.quickConnectStart() } catch {
                if Task.isCancelled { return }
                let text = readableError(error)
                onMainThread { self.accountErrorShow(text) }
                return
            }
            if Task.isCancelled { return }
            onMainThread {
                self.accountCode = preGait.code
                gtk_label_set_text(OpaquePointer(self.accountCodeField), preGait.code)
            }
            // Deadline, interval, network errors: ``Quickconnectwarten`` in the package.
            // The remaining time arrives every second, not at the poll interval.
            for await event in c.quickConnectWait(preGait) {
                if Task.isCancelled { return }
                switch event {
                case let .rest(seconds):
                    onMainThread { self.accountRemainingShow(seconds) }
                case let .end(last):
                    let text = QuickConnectDeadline.endText(last: last)
                    onMainThread {
                        self.accountRemainingShow(nil)
                        self.accountErrorShow(text)
                    }
                    return
                case .released:
                    do {
                        let session = try await c.signInWithQuickConnect(preGait)
                        if Task.isCancelled { return }
                        onMainThread {
                            self.accountCode = ""
                            self.accountError = ""
                            self.accountPerCode = false
                            self.accountCodeRun = nil
                            self.sessionRecord(session, serverName: serverName)
                            self.subpageOpen(.profile, push: .without)
                        }
                    } catch {
                        let text = readableError(error)
                        onMainThread {
                            self.accountRemainingShow(nil)
                            self.accountErrorShow(text)
                        }
                    }
                    return
                }
            }
        }
    }

    /// "Läuft ab in 4:58"; `nil` hides the line.
    private func accountRemainingShow(_ seconds: Int?) {
        guard let inputField = accountRemainingField else { return }
        guard let seconds, seconds > 0 else {
            gtk_widget_set_visible(inputField, 0)
            return
        }
        // Same key as on Apple: seconds arrive as a finished two-digit text, the
        // catalog only knows minutes and rest.
        let text = String(format: translated("Läuft ab in %lld:%@"),
                          seconds / 60, String(format: "%02d", seconds % 60))
        gtk_label_set_text(OpaquePointer(inputField), text)
        gtk_widget_set_visible(inputField, 1)
    }

    /// A message in the line below the fields, **not** where the code is. Keeping
    /// the two apart is half the reason this page is separate.
    private func accountErrorShow(_ text: String) {
        accountError = text
        guard let inputField = accountStateField else { return }
        gtk_label_set_text(OpaquePointer(inputField), text)
        gtk_widget_set_visible(inputField, text.isEmpty ? 0 : 1)
    }

    private func saveBundle(serverName: String?) {
        guard let bundle else { return }
        Cache.writeBundle(.init(bundle: bundle, serverName: serverName))
    }

    /// Puts a session into service: client, image addresses, display, loading.
    private func sessionInSet(_ session: Session, serverName: String?) {
        let serverURL = session.serverURL
        let token = session.accessToken
        let userIdentifier = session.userID
        let username = session.userName
        // **With version.** Without `clientVersion` the default
        // `Fassungsnummer.outBundle` applies; there is no bundle here, and the
        // Jellyfin dashboard showed "Swiftly Player unbekannt". This is the path on
        // every start with a stored session.
        let c = JellyfinClient(baseURL: serverURL,
                               deviceID: Device.identifier,
                               deviceName: Device.name,
                               clientVersion: Device.version)
        AppLog.writeOut("[Sitzung] Client-Fassung \(Device.version)")
        fflush(nil)
        addresses = ImageAddress(base: serverURL, token: token)
        self.userIdentifier = userIdentifier
        // **Direct Play and the bitrate limit belong to the server** (like
        // `AppModel.serverKey` on Apple): one server may transcode, another
        // not.
        selection.activeServer = serverURL.absoluteString
        // The previous account's default does not apply to this one.
        nextAutomaticAccount = nil
        downloadPermission = .unknown
        convertAllowed = true
        downloadQualitySelectable = true
        // **Downloads belong to the account.** Two accounts on one server carry the
        // same IDs; without the account, one's progress would show on the other's
        // title.
        downloads.change = { [weak self] in
            guard let self, self.section == .downloads else { return }
            self.downloadsPageFill()
        }
        sessionShow(username: username, serverName: serverName)
        switchStack(pages, toward: "start")

        // **`JellyfinClient` is an actor.** Setting the session therefore needs
        // `await`; only afterwards may loading start.
        Task.detached { [self] in
            await c.setSession(session)
            onMainThread {
                self.client = c
                self.downloads.signIn(client: c, account: userIdentifier)
                self.accountPreGiftFetch(c)
                // **What the server says by now.** On Apple the same reconciliation runs
                // every time the main view appears.
                self.downloads.follow()
                self.loaded = [.start]
                self.homeLoad()
                self.librariesLoad()
                // **And the section the user is on, if it is not the home screen.** After
                // an account switch the section stays, and without this line it would show
                // the previous account's list, since `loaded` only knows `.start` and nobody
                // asks.
                if self.section != .start { self.show(self.section) }
                // **Only here, not earlier.** `client` is not set above; it goes through the
                // actor and is only there after `setSession`. Everything starting with
                // `guard let client` used to exit silently: the remote control never reported
                // its capabilities, so the iPhone did not see the Linux session as
                // controllable. The takeover poll did not notice because it asks every ten
                // seconds anyway and healed itself.
                self.serverStateFetch()
                self.remoteControlStart()
                self.takeoverTickStart()
                self.sharedStart()
            }
        }
    }

    // MARK: - The window after sign-in

    private var titleLine: Widget!
    var content: Widget!            // GtkStack: start / movies / series / search
    /// The stage: a `GtkFixed` on which the list layer and the two detail layers
    /// lie on top of each other. It clips whatever overhangs.
    var stage: Widget!
    /// Which layer is currently on top.
    var onTop: Widget!
    /// The stage size reported last.
    var stageWidth: Int32 = -1
    var stageHeight: Int32 = -1
    /// **By section, not by position in the list.** This used to be an array
    /// parallel to `Region.allCases`; once the bar splits into two groups and one
    /// of them is only sometimes present, positions no longer match the enum and
    /// the wrong row gets highlighted. Same rework as for the grid pages.
    private var sectionButtons: [Region: Widget] = [:]
    /// The "Meins" group and its rows; rebuilt when the downloads switch is
    /// toggled.
    private var myList: Widget!
    /// Its heading; hidden when neither downloads nor the watchlist are on.
    private var mineCategory: Widget!
    /// **Which collection is currently open as a subpage**, `nil` if none. `art`
    /// says whether its movies or its series are meant (Mac `CollectionDetailPage`).
    var openCollection: (item: Item, art: String?)?
    /// Where the collection was opened from. The back arrow leads there, and that
    /// sidebar row stays highlighted, as on the Mac where the collection lies in
    /// its section's stack.
    var collectionOrigin: Region = .movies
    /// **Filter and sort of a collection are not remembered** (Mac
    /// `MacCollection.swift`): a collection is not a place to return to but a view
    /// into a row. Defaults to year, ascending (``Regalquelle/richtung(_:)``).
    var collectionSorting: Sorting = .erscheinung
    var collectionFilter: LibraryFilter = .all
    /// The title of the collection page. It changes with every collection; the
    /// section pages have a fixed title.
    private var collectionTitle: Widget!
    /// The title of the genre page. It carries the **untranslated** name from the
    /// server.
    private var genreTitle: Widget!
    /// The server-name line per grid page.
    private var serverRows: [Region: Widget] = [:]
    /// Which genre is currently open.
    var openGenre: String?
    /// Which kind the watchlist shows.
    /// **Persisted, not just remembered.** It was a plain in-memory value and reset
    /// to "Filme & Serien" on every start; on the Mac it lives in `UserDefaults`
    /// (`WatchlistModel.swift`).
    var savedGenre: RememberGenre {
        get { RememberGenre(rawValue: selection.savedGenre) ?? .all }
        set { selection.savedGenre = newValue.rawValue; selection.secure() }
    }
    private var profileImage: Widget!
    private var profileName: Widget!
    private var profileServer: Widget!
    /// **The grid pages live in dictionaries, not pairs.**
    ///
    /// Previously there was `was == .movies ? movies... : seriesList...` in eight
    /// places. With a third section (watchlist) each would have become a
    /// three-way chain, and every forgotten spot would silently have filled the
    /// wrong page. A dictionary has no special case.
    private var gridField: [Region: Widget] = [:]
    private var numberField: [Region: Widget] = [:]
    var searchField: Widget!
    /// "Zuletzt gesucht": shown while the field is empty.
    private var searchHistoryBlock: Widget!
    /// Whether both search blocks are empty; "Nichts gefunden" only applies if
    /// **both** are.
    var ownHitEmpty = true
    var seerrHitEmpty = true
    private var searchHint: Widget!
    private var searchHistoryList: Widget!
    var searchGrid: Widget!
    var searchEmpty: Widget!
    /// Shown instead of "Nichts gefunden" when the server did not answer at all.
    var searchDisturbance: Widget!
    var loaded: Set<Region> = []
    /// Filter and sort, separate per section. On the Mac each section keeps its
    /// own state, so switching between movies and series returns to where the user
    /// was.
    private var filter: [Region: LibraryFilter] {
        get {
            var d: [Region: LibraryFilter] = [:]
            for (k, v) in selection.filterPerPlace {
                if let b = Region.allCases.first(where: { $0.identifier == k }),
                   let f = LibraryFilter(rawValue: v) { d[b] = f }
            }
            return d
        }
        set { }
    }
    /// **The watchlist starts on "Zuletzt", not A-Z.** That is the order a
    /// watchlist is read in: the most recently added is on top. On Apple it is the
    /// default of `WatchlistModel.sorting`; here it was defined nowhere, so
    /// `?? .name` applied.
    /// What currently applies, read from ``Wahlen`` and written via
    /// ``sortingSet(_:_:)``.
    private var sorting: [Region: Sorting] {
        get {
            var d: [Region: Sorting] = [.watchlist: .latest]
            for (k, v) in selection.sortingPerPlace {
                if let b = Region.allCases.first(where: { $0.identifier == k }),
                   let s = Sorting(rawValue: v) { d[b] = s }
            }
            return d
        }
        set { }
    }

    /// **The name under which a place's filter and sort are stored.**
    ///
    /// A genre keeps its state by name. **A collection remembers nothing**
    /// (``collectionSorting``); the key exists only so there is one.
    private func placeKey(_ was: Region) -> String {
        switch was {
        case .collection:   return "sammlung"
        case .genre:    return "gattung:" + (openGenre ?? "")
        default:          return was.identifier
        }
    }

    /// What applies at this place. **The watchlist starts on "Zuletzt"**, the
    /// order a watchlist is read in.
    func sortingFrom(_ was: Region) -> Sorting {
        if was == .collection { return collectionSorting }
        if let raw = selection.sortingPerPlace[placeKey(was)],
           let s = Sorting(rawValue: raw) { return s }
        return was == .watchlist ? .latest : .name
    }

    func filterFrom(_ was: Region) -> LibraryFilter {
        // A stored filter the page no longer offers (the watchlist, switched off) reads as "All".
        if was == .collection { return collectionFilter.kept(in: filterList(was)) }
        if let raw = selection.filterPerPlace[placeKey(was)],
           let f = LibraryFilter(rawValue: raw) { return f.kept(in: filterList(was)) }
        return .all
    }

    private func sortingSet(_ was: Region, _ new: Sorting) {
        if was == .collection { collectionSorting = new; return }
        selection.sortingPerPlace[placeKey(was)] = new.rawValue
        selection.secure()
    }

    private func filterSet(_ was: Region, _ new: LibraryFilter) {
        if was == .collection { collectionFilter = new; return }
        selection.filterPerPlace[placeKey(was)] = new.rawValue
        selection.secure()
    }
    private var chipRows: [Region: Widget] = [:]
    /// The placeholder content of a grid page with nothing to show, only where
    /// the Mac has one.
    private var emptyField: [Region: Widget] = [:]
    /// The small title in the `Bestandsleiste` per section; it changes when a
    /// library or genre brings a different name.
    var barTitle: [Region: Widget] = [:]

    /// Symbol, heading and explanation of the empty state, matching the Mac
    /// word for word. `nil` means there is none.
    private func emptyText(_ was: Region) -> (String, String, String?)? {
        switch was {
        // Mirrors the empty state in `WatchlistView.swift`.
        case .watchlist:
            return ("bookmark-new-symbolic", translated("Noch nichts gemerkt"),
                    translated("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier."))
        // Mirrors the empty state in `GenreView.swift`.
        case .genre:
            return ("tag-symbolic", translated("Nichts in diesem Genre"),
                    translated("In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien."))
        default: return nil
        }
    }
    var userIdentifier = ""
    var searchTick = 0

    // MARK: Page stacks
    //
    /// **One stack per section**, like `Navigator` on the Mac: switching between
    /// movies and series returns to where the user was.
    var pagesStack: [Region: [Item]] = [:]
    /// The season a series page opens with; set when the path led through an
    /// episode.
    var startSeason: String?
    /// The season **number** the user came through, a second route next to the
    /// ID. Measured on a device: the server does not always deliver a `SeasonId`
    /// for an episode; then the ID comparison misses and only the number remains.
    var startSeasonNumber: Int?
    /// The role through which a person page was reached, and the title it was
    /// played in.
    ///
    /// **Side data next to the stack, like `startSeason`.** On Apple `PersonRoute`
    /// carries both; here the stack holds `Item`, and a role is in no item: it
    /// belongs to the *link* between title and person, not to the person.
    /// Rebuilding the stack around an enum of destinations would touch every page,
    /// for two strings.
    /// Server onboarding state: address, checked name, error.
    var serverOnboardingAddress = ""
    var serverOnboardingChecked: String?
    var serverOnboardingError = ""
    var serverOnboardingPreGiven = false
    var serverOnboardingState: Widget!
    var serverOnboardingButton: Widget!
    /// "Advanced" when adding a server: custom headers (issue #4).
    var serverOnboardingHeaders: [OwnHeader] = []
    /// The checked address that is being signed in to.
    var serverOnboardingURL: URL?

    var personRole: String?
    var personOrigin: String?
    /// Where the main button of the open detail page points, and which season is
    /// selected there. The more-list needs both, otherwise "Folge von vorn" and
    /// "Staffel als gesehen" could not be offered.
    var openTarget: PlayTarget?
    /// **Refresh watch state in place** (after the player). Each episode row and
    /// the main button register here how to redraw; the marker prevents clearing
    /// an old page from deleting the new page's entry.
    var watchStateRows: [String: (mark: Int, refresh: (Item) -> Void)] = [:]
    var headerRefresh: (mark: Int, perform: () -> Void)?
    var watchStateMarks = 0
    /// The scroll area of the open detail page, for logging, so it can be shown
    /// that it stays put after the player.
    var detailScroller: Widget?
    func nextWatchStateMark() -> Int { watchStateMarks += 1; return watchStateMarks }
    var openSeason: Item?
    /// The hint line of the detail page.
    var hintField: Widget!
    /// The slot for the badge on the movie page being built. Set while building
    /// and read right away; the request holds it itself.
    var occupiedRoom: Widget!
    /// The pending work behind the sparse first version of a detail page, not
    /// yet started. See ``titleLoadMore``.
    var likesBase: (() -> Void)?
    /// The topmost overlay of the window, where the Discord hint sits.
    var windowCover: Widget?
    /// Support state (``SupportFile``), the watched-time counter and the open layers.
    var supportStore = App.makeSupportStore()
    /// Keeps the stored supporter key and its status current (expiry, renewal, refund).
    lazy var supportKeeper = SupporterKeyKeeper(store: supportStore)
    /// The look the window wears and the try-on rules (``LookModel``), in the same file.
    lazy var looks = LookModel(storage: supportStore.storage, supporter: supportStore.status.isSupporter)
    /// Brings the open looks panel up to date after a change; `nil` while it is closed.
    var lookPanelSync: (() -> Void)?
    /// True while the looks panel hands its try-on over to the purchase page.
    var lookKeepHeld = false
    var supportCounter = WatchTimeCounter()
    let supportLaunch = Date()
    var supportCard: Widget?
    var supportSheet: Widget?
    var supportKeyField: Widget?
    /// The thank-you wanted to appear during playback and waits for the player to close.
    var supportThanksDue = false
    /// The running account switch with flight (``Kontoflug``), otherwise `nil`.
    var accountTransition: AccountTransition?
    /// The running "Hier weiterschauen" handover as a card (``Uebergabelauf``),
    /// otherwise `nil`.
    var handoff: HandoffRun?
    /// **Who is taking over.** Arrives as a hint shortly before the stop
    /// (``JellyfinClient/handoffHint(an:geraet:)``). With a fresh hint the
    /// picture leaves as a card on stop; otherwise the player closes as usual
    /// (Apple `AppModel.handoffTarget`).
    var handoffTarget: (name: String, time: Date)?
    /// The home screen was not loaded yet at the swap; its rows still arrive
    /// staggered once they are there.
    var accountTransitionSeasonPostGl = false
    /// Running ``switchStack`` per stack; the newest wins.
    var stackSwitch: [UnsafeMutableRawPointer: Int] = [:]
    var stackSwitchCounter = 0
    /// The running step-by-step build of an episode list; a new one (other
    /// season, other page) ends the old one.
    var episodesLayout = 0
    var discordCard: Widget?
    var discordHintDue = false
    /// Which title was counted last (``readyCount``).
    var countedTitle: String?
    var hintTick = 0
    /// Which subpage is open (profile, Quick Connect, ...), `nil` if none. They do
    /// not live in the section stack: on the Mac they also lie across it.
    var openSubpage: Subpage? { didSet { sectionRowsDraw() } }
    var openList: ValuesSelection?
    var selection = Choices.read()

    /// Shorthand for `selection.downloadsAn`; the bar and the detail page ask for it
    /// often.
    var downloadsAn: Bool { selection.downloadsAn }

    /// **Whether a download button appears**: the switch *and* the account's
    /// right, decided in the package (`DownloadPermission`, like
    /// `AppModel.downloadButtonShow` on Apple).
    ///
    /// The bar and the settings row stay on `downloadsAn`: what is on disk must
    /// remain reachable even if the account may no longer download.
    var downloadButtonShow: Bool {
        DownloadPermission.offer(rights: downloadPermission, functionOn: downloadsAn)
    }

    /// What is stored on this machine. The rules are in the package, the download
    /// process in `DownloadManager`; only the UI hooks into it here.
    let downloads = DownloadManager()

    // MARK: Downloads page: widgets and state
    var list: Widget!
    var downloadAllocation: Widget!
    var downloadRemove: Widget!
    var downloadEditButton: Widget!
    var downloadEmpty: Widget!
    var downloadEdit = false
    var downloadSelected: Set<String> = []

    // MARK: Seerr title page
    var seerrBlock: Widget!
    var seerrDetails: Widget!
    var seerrAction: Widget!
    var seerrButtonRail: Widget!
    /// Which seasons are to be requested. Empty means none selected yet, and then
    /// the button requests none.
    var seerrSelectedSeasons: Set<Int> = []
    /// **The first press asks, the second sends.** Only for a movie; for a series
    /// the season selection is the second stage. Reset when a Seerr page opens.
    var seerrConfirmed = false
    /// Whether the season list of a Seerr series is expanded: the first press on
    /// the main button opens it, the second sends the request.
    var seerrSeasonsOpen = false
    var seerrSeasonExpand: Widget?
    /// The request state on the open Seerr page, like `running`, `requested` and
    /// `error` in `SeerrTileAndPage.swift`. Reset when a Seerr page opens.
    var seerrRuns = false
    var seerrRequested = false
    /// The title's state as the server last reported it (`SeerrDetail.state`);
    /// `nil` while only the search hit exists.
    var seerrState: SeerrState?
    var seerrError: String?
    /// The confirmation before switching off, in the settings.
    var downloadDisablePrompt: Widget!
    var username = ""
    /// The server name. **It is also in the header of every grid page**, so the
    /// pages redraw when it changes.
    var serverName = "" { didSet { if serverName != oldValue { serverRowsDraw() } } }
    var serverVersion = ""
    /// What is already in the grid and how many the server has in total, for
    /// loading more while scrolling.
    var gridItems: [Region: [Item]] = [:]
    var gridTotal: [Region: Int] = [:]
    var gridLoads: Set<Region> = []
    var gridJob: [Region: Int] = [:]
    var loaderField: [Region: Widget] = [:]
    /// Remote control over Jellyfin's socket. Without it the server reports
    /// `SupportsRemoteControl: false` and hides the dashboard's buttons.
    var remoteControl: RemoteControl?
    /// Watch together: one for the whole app; see ``Gemeinsamstand``.
    let gemeinsam = SharedState()
    /// Media keys and the desktop's playback tile.
    var mediaBar: MediaBar?
    var takeoverRow: Widget!
    private var takeoverTitle: Widget!
    /// Until when an error stays in the takeover row.
    private var takeoverErrorUntil = Date.distantPast
    private var takeoverCharacter: Widget!
    /// What the row above says: "Hier weiterschauen", "Gemeinsam schauen" or,
    /// with more than one offer, "Läuft gerade".
    private var takeoverTop: Widget!
    /// The counter, once there is more than one offer.
    private var takeoverCounter: Widget!
    private var takeoverOfferings: [RemoteSession] = []
    /// Devices a film can be handed to, from the same poll (`PlayOn.swift`).
    ///
    /// **The player's TV button follows the list**: the poll keeps running while a
    /// film plays, so a TV switched on later must show up in the icon row too.
    var playTargets: [RemoteSession] = [] { didSet { playHandOverRefresh() } }
    /// **Tracks sent along with a title from another device**, for that title only;
    /// `tracksPreSelect` takes them once and forgets them.
    var playOrderedTracks: (itemID: String, tracks: TrackIndices)?
    /// Counts incoming orders, so that only the latest one opens.
    private var playReceivedCount = 0
    private var takeoverRun: Task<Void, Never>?
    /// Intro and outro markers of the running title, from the server.
    var sections: [Segment] = [] {
        // The notches on the time slider sit at their boundaries.
        didSet { if let k = playerNotches { gtk_widget_queue_draw(k) } }
    }
    /// **The running version's chapters**, already cleaned up
    /// (``Kapitelleiste/brauchbar(_:)``); empty if the file has none.
    /// With chapters, the bar overlay draws the segments itself and the slider
    /// track becomes transparent (`swiftly-regler-kapitel`).
    var playerChapter: [Chapter] = [] {
        didSet {
            if let r = playerSlider {
                if playerChapter.isEmpty { gtk_widget_remove_css_class(r, "swiftly-regler-kapitel") }
                else { gtk_widget_add_css_class(r, "swiftly-regler-kapitel") }
            }
            if let k = playerNotches { gtk_widget_queue_draw(k) }
        }
    }
    var currentOffering: ButtonOffering = .nobody
    /// **"Intro überspringen" and "Nächste Folge" over the picture**, without the
    /// controls having to open. The package decides what appears when.
    /// **The card waits while the controls are deliberately open**
    /// (`cardWaitsControls`): it disappears, the countdown pauses, and it
    /// returns when they close. It is only dismissed via X or Escape.
    var offeringLayer: OfferingLayer = {
        var e = OfferingLayer()
        e.cardWaitsControls = true
        return e
    }()
    /// The account's `EnableNextEpisodeAutoPlay`. Not stored: fetched fresh at
    /// every sign-in, since another account has another value.
    var nextAutomaticAccount: Bool?
    /// The account's `Policy.EnableContentDownloading`, from the same response.
    /// `.unknown` means allowed: a network error takes nothing away.
    var downloadPermission: DownloadPermission = .unknown
    /// The account's `Policy.EnableVideoPlaybackTranscoding`, from the same
    /// response. Without an answer: allowed, so the quality choice stays in the
    /// player, like `AppModel.convertAllowed` on Apple.
    var convertAllowed = true
    /// Whether a lower quality can be chosen when downloading: video and audio
    /// permission, decided in the package (`DownloadQuality.waehlbar`).
    var downloadQualitySelectable = true
    /// **The open player's episode switching**: the flow from the package, the
    /// same as on iOS, tvOS and macOS. It holds the latch (one switch at a time),
    /// and `close` cancels a running one. Every open gets a fresh one: an old
    /// switch whose player is closed recognizes itself by no longer being stored
    /// here.
    var episodesSwitch = EpisodeSwitch()
    /// What should happen after the player's end report; set only if the window
    /// closes during playback. See ``windowCloseRequested()``.
    var postStop: (() -> Void)?
    var closesPostStop = false
    /// **The next episode, fetched ahead.** Only when it exists are the button,
    /// the media key and the advance available; before, every episode counted as
    /// having a successor, including the finale.
    var prefetchedEpisode: Item?
    /// Sections (by start second) already skipped on their own in this episode: once per section.
    var autoSkipped: Set<Double> = []
    /// The running "Zufällig abspielen" order or playlist, if any; it applies as long as the playing
    /// title belongs to it.
    var shuffleRun: ShuffleRun?
    /// The section a playlist was opened from (`area|id`) -> its kind (`movies`, `tvshows`, empty: all).
    var playlistArt: [String: String] = [:]
    /// Plan and file head of the next episode, fetched in the last minutes
    /// (``EpisodePreparation``, iOS `preparation`).
    let preparation = EpisodePreparation()
    /// **The one queue for start, progress and stop**, the same as
    /// `AppModel.messages` on Apple. Ordering, coalescing, a 6 s deadline per
    /// report and the stop lock per PlaySession are in the package; here only
    /// what is sent is defined. The former own `StopLock` was absorbed into it.
    let messages = ReportQueue<ReportContent> { message in
        let content = message.payload
        let client = content.client, title = content.title, plan = content.plan
        #if DEBUG
        // Remote control `messages:hanging`: a server that does not answer.
        if ReportProbe.hanging { try await Task.sleep(nanoseconds: 60_000_000_000) }
        #endif
        switch message.art {
        case .start:
            // **The capabilities before every start**, like Apple and Android: after a
            // server restart the device was otherwise not controllable until the app was
            // restarted. If it fails, the start proceeds anyway, unless the deadline
            // cancelled it.
            do { try await client.reportCapabilities() } catch {
                try Task.checkCancellation()
                AppLog.writeOut("[Uebernahme] Faehigkeiten nicht gemeldet")
            }
            try await client.reportStart(itemID: title.id, plan: plan, ticks: content.ticks,
                                         tracks: content.tracks)
            AppLog.writeOut("[Melden] Start \(content.ticks / 10_000_000) s \(title.id) session \(plan.playSessionID ?? "nil")"
                  + " Spuren \(content.trackText)")
        case let .progress(paused):
            try await client.reportProgress(itemID: title.id, plan: plan,
                                            positionTicks: content.ticks, paused: paused,
                                            tracks: content.tracks)
            AppLog.writeOut("[Melden] Progress \(content.ticks / 10_000_000) s pausiert \(paused) \(title.id)"
                  + " Spuren \(content.trackText)")
        case .stop:
            try await client.reportStopped(itemID: title.id, plan: plan,
                                           positionTicks: content.ticks)
        }
        fflush(nil)
    }
    /// What the server currently knows as playing; set at start, cleared at stop.
    /// Pause, resume and seek report from it without asking the player; before
    /// start and after stop there is nothing.
    var reportTitle: (client: JellyfinClient, title: Item, plan: PlaybackPlan)?
    /// The last playback state reported; libVLC's event reports a change only
    /// once.
    var reportedPaused = false
    /// Whether the user has already chosen something on the open detail page.
    /// The panel most recently opened by the More button. It is detached on the
    /// next click, otherwise they would pile up on the button.
    var openPanel: Widget?

    /// **Open a panel and track it correctly.**
    ///
    /// The previous one is removed, otherwise after the third click the third panel
    /// would hang on the button with the two earlier ones beside it. And the new
    /// one forgets itself as soon as GTK tears it down: `panelAn` detaches it when
    /// the anchor is destroyed, and a field still pointing at it would be a pointer
    /// to freed memory. The next click on "Mehr" used to crash; confirmed in the
    /// core, not guessed.
    ///
    /// Same class of bug as the drawing areas that must keep themselves alive:
    /// anyone storing a GTK object in a Swift field must listen for its end.
    func panelOpen(an button: Widget!, style: String = "swiftly-mehr",
                      flush: GtkAlign = GTK_ALIGN_START) -> Widget! {
        panelClose()
        let panel = panelAn(button, style: style, flush: flush)
        openPanel = panel
        signal(panel, "destroy") { [weak self] in self?.openPanel = nil }
        return panel
    }

    func panelClose() {
        guard let alt = openPanel else { return }
        openPanel = nil
        gtk_widget_unparent(alt)
    }
    /// The centered window (``panelWindowOpen(_:content:closed:)``) while it is
    /// open, and what runs when it closes.
    var panelWindow: Widget?
    var panelWindowClosed: (() -> Void)?
    var detailTouched = false
    /// The last result of "Verbindung prüfen".
    var checkResult = ""
    /// "Läuft ab in 4:58" below the Quick Connect code.
    var accountRemainingField: Widget!
    /// **Seasons and episodes, fetched once.**
    ///
    /// The Mac has `Seriencache` for this: leaving a series page and coming back
    /// shows it immediately. On Linux everything was fetched again with "Lade ..."
    /// first, the same wait every time for a series opened repeatedly.
    var seasonCache: [String: [Item]] = [:]
    var episodeStore: [String: [Item]] = [:]

    /// **What is stored here also carries the watch state.**
    ///
    /// The remembered episodes carry `userData`, i.e. check mark and progress.
    /// Marking an episode changes the state on the server; what is stored here
    /// knows nothing of it, and the next time the season opens it is unwatched
    /// again.
    ///
    /// The same bug was fixed on iPhone (`Sources/Shared/AppModel.swift`): a whole
    /// season marked, back, in again, and everything was unwatched. Same store,
    /// same trap, only in GTK.
    ///
    /// **Discard instead of patching.** Changing the check mark in the stored
    /// `Item` would mean rebuilding `Item` and `UserItemData`; the store is there
    /// so the way back is not empty, not to hold the truth about watch state.
    func watchStateForget(_ item: Item) {
        let series = item.seriesId ?? item.id
        for season in seasonCache[series] ?? [] { episodeStore[season.id] = nil }
        seasonCache[series] = nil
        // The season itself and the season an episode is in: both can be stored
        // without the series being stored.
        episodeStore[item.id] = nil
        if let season = item.seasonId { episodeStore[season] = nil }
        // Changing the watch state also changes what the lists show.
        listenRefresh()
    }

    /// **Lists refresh after watch state and watchlist changes** (Mac:
    /// `listenRefresh`). After playback, "Als gesehen" or watchlist changes,
    /// check marks and bars in movies, series, watchlist and genre would otherwise
    /// be stale. What is on screen reloads immediately, **as many as already
    /// shown** (up to 300), otherwise the list would shrink to the first page; the
    /// rest counts as unloaded and loads on the next visit.
    func listenRefresh() {
        for was in [Region.movies, .seriesList, .watchlist, .genre] {
            guard loaded.contains(was), gridField[was] != nil, !gridLoads.contains(was) else { continue }
            if section == was {
                gridLoad(was, reach: min(300, max(100, (gridItems[was] ?? []).count)))
            } else {
                loaded.remove(was)
            }
        }
        // And an active search: its tiles carry check marks and bars too.
        if section == .search, searchField != nil,
           DisplayRules.searchTermFits(text(searchField).trimmingCharacters(in: .whitespacesAndNewlines)) {
            searchTick += 1
            searching(searchTick)
        }
    }

    // MARK: Player
    /// **Only on the first playback.** The player creates a `GtkPicture`, and
    /// ``App`` is a global reference created **before** `g_application_run`
    /// initializes GTK. A widget before `gtk_init` crashes inside libgtk, with no
    /// line of our own code in the backtrace.
    lazy var mediaPlayer: Player = {
        let new = Player()
        // Pause and resume reach the server via VLC's event.
        new.runState = { [weak self] running in
            guard let self else { return }
            // No screensaver during playback, allowed again on pause. Only with an open
            // player: a "playing" that arrives only after closing would otherwise keep
            // the screen awake until the next movie.
            GuardHolder.setDown(running && self.runningTitle != nil, window: self.window)
            self.runStateReported(running: running)
        }
        new.tornDown = { [weak self] error in self?.streamTornDown(error: error) }
        return new
    }()
    #if os(Windows)
    /// Where the update row in the settings currently stands. Windows only; on
    /// Linux the package source handles it.
    enum UpdateStatus {
        case unknown
        case hunts
        case current
        case new(Update.Snapshot)
        case loads
        case wentWrong(String)
    }
    var updateStatus: UpdateStatus = .unknown
    /// The box holding the row; it is rebuilt on every state change and needs
    /// its place.
    var updateSpace: Widget?
    #endif
    var runningTitle: Item?
    /// **The TV button waits for the plan**: the icon row is built before it
    /// arrives, and only a stream from the server can be handed over.
    var runningPlan: PlaybackPlan? { didSet { playHandOverRefresh() } }
    /// The next plan comes from a quality choice, for the hint.
    var qualitySwitched = false
    /// Audio, subtitles and sideloaded files of the running title; see
    /// ``Spurlage``.
    let trackStatus = TrackStatus()
    var playState = PlaybackTick.Snapshot()
    var sinceOpen = Date()
    var playerTick: guint = 0
    var controlsTick = 0
    var playerControls: Widget!
    var playerTime: Widget!
    var playerRemaining: Widget!
    var playerSlider: Widget!
    /// The notches above the time slider (``notchesDraw``) while it exists.
    var playerNotches: Widget?
    /// The duration the notches were last drawn with.
    var notchesDuration: Double = 0
    /// Counts the player pages; see ``playerOpen(_:since:)``.
    var playerCounter = 0
    var playerPlayMarker: PlayerCharacter?
    var playerNext: OfferingButton?
    /// The same button as a separate layer over the picture, while the controls
    /// are collapsed.
    var playerOffering: OfferingButton?
    /// **The next-episode card** (variant C, ``EpisodeCardsView``) and the
    /// scrim below it that darkens the picture while it is shown.
    var playerCard: EpisodeCardsView?
    var playerCardsScrim: Widget?
    var playerTrackButton: Widget!
    /// Keeps the drawn slider glyph of the playback chip alive while the player
    /// page exists.
    var playerSliderCharacter: SliderCharacter?
    var playerFullButton: Widget!
    /// **"Übergeben an …" in the icon row.** Built with the row and only shown
    /// while a hand-over is possible (``playHandOverRefresh()``).
    var playerHandOverButton: Widget!
    /// The empty slot beside the standing title that keeps the icon row free; it
    /// changes width with the TV button.
    var playerRailsSlot: Widget!
    /// **The TV window is open**: the controls stay, as while the volume handle is
    /// dragged, so the film does not lose its controls behind the window.
    var handOverOpen = false
    var playerLoadingScreen: Widget!
    /// Whether the time slider is currently being dragged.
    var atSlider = false
    /// Alternates on every call: `clockOut` alternately only updates the time and
    /// computes the full tick.
    var onlyTimeTick = false
    /// Counts the full ticks while waiting for the first frame.
    var startWait = 0
    /// When the playback tick last ran, for the gap watchdog.
    var lastTick: ContinuousClock.Instant?
    /// The fill of the "Nächste Folge" card as a continuous motion.
    var offeringClock = FillClock()
    var playerWarning: Widget!
    var playerWarnText: Widget!
    /// The two circular arrows. They show the skip distance as a number and must
    /// update it when it changes in the settings.
    var playerBackCharacter: PlayerCharacter?
    var playerPreCharacter: PlayerCharacter?
    /// The skip indicator at the edge of the picture.
    var playerJumpLeft: JumpMark?
    var playerJumpRight: JumpMark?
    var jumpTick = 0
    /// What the skip marker currently sums up: direction and seconds (iOS
    /// `jumpDisplay`).
    var jumpSum: (back: Bool, seconds: Int)?
    var playerFrame: Widget!
    /// One of the three layers over the picture (audio & subtitles, settings,
    /// episodes), or `nil` if none is open. Literally `openLayer` on the Mac
    /// (`PlayerScreen.swift`), but as a GTK widget instead of state: it is rebuilt
    /// on every open, and there is no switching without rebuilding (GTK has no
    /// equivalent of SwiftUI's `switch` over content).
    var openLayer: Widget!
    var openLayerArt: PlayerLayer?
    /// **The title, independent of the controls** (Mac: `stateTitle`).
    ///
    /// Unlike the Mac, not a second overlapping widget: a single one that is never
    /// removed while the player is open. That prevents flicker when the episode
    /// layer opens, without needing two copies.
    var playerTitleState: Widget!
    var playerTitleRow: Widget!
    /// The invisible title in the controls' header that reserves the meta line's
    /// place under the standing title.
    var playerTitleSpace: Widget!
    /// Under the title: the meta line ("Staffel 1 · Folge 3"), or, when the
    /// episode layer is open, the season picker in its place.
    var playerMetaRow: Widget!
    var playerSeasonSelection: Widget!
    /// The episode list of the open episode layer and its scroller, as a field
    /// and not a local variable: a `Task.detached` that returns later must not
    /// carry a GTK widget in its closure (Swift 6 requires `Sendable`, and a
    /// `Widget` is not). Going via `self` (which counts as `@unchecked Sendable`)
    /// takes the same path safely.
    var playerEpisodesList: Widget!
    var playerEpisodesScroller: Widget!
    /// The glyph in the fullscreen icon button, swapped when the fullscreen state
    /// changes (``fullscreenToggle()``).
    var playerFullscreenImage: PlayerCharacter?
    /// Whether the window was already fullscreen before the player; see
    /// ``playerClose(report:windowBack:)``.
    var fullscreenPrePlayer = false
    /// Whether the controls should currently be shown: the state, not the
    /// opacity, which is an intermediate value during a fade.
    var controlsOpen = false
    /// The three buttons in the middle and the icon row at the top right; both
    /// make way for the preview while the slider is dragged (Mac: `atSlider`).
    var playerCenter: Widget!
    var playerIconRail: Widget!
    /// The volume slider at the far left of the icon row; `volumePulls`
    /// keeps the controls visible while someone drags the handle.
    var playerVolume: VolumeSlider?
    var volumePulls = false
    var volumeClock = 0
    /// The wheel has changed the value; it is not saved yet.
    var volumeWheelOpen = false
    /// The button that opened a layer; focus returns to it when the layer closes.
    var playerLayersButtons: [PlayerLayer: Widget] = [:]
    /// The episode the episode list scrolls to once it is laid out.
    var playerEpisodesTarget: Widget!
    /// The X of the open layer; it gets focus on open.
    var playerLayersX: Widget!
    /// The season whose episodes are being loaded; a later response for another
    /// season is discarded.
    var playerEpisodesSeason: String?
    /// Trickplay preview at the time slider: `nil` while no server sheet is
    /// loaded or the pointer is not over the bar.
    var playerTrickplay: TrickplayImages?
    var playerPreview: Widget!
    var playerPreviewImage: Widget!
    var playerPreviewTime: Widget!
    /// The chapter name before the time in the preview; empty and hidden without
    /// chapters.
    var playerPreviewName: Widget!
    var playerPreviewWrapper: Widget!
    /// The technical overlay over the movie, `nil` when off.
    var techBadge: Widget!
    /// The last state of the counters; the next measurement computes from it.
    var techCounter: Counter?
    /// Seerr: credentials and client, `nil` while nothing is set up.
    var seerrAccess: SeerrAccess?
    var seerrClient: SeerrClient?
    /// Whether the stored Seerr session still works. `nil` means not checked yet;
    /// reset on disconnect and on connect.
    var seerrApplies: SeerrSessionState?
    /// The Seerr results of the search: heading and grid below.
    var seerrHeading: Widget!
    /// The row of heading and count badge; shown and hidden as a whole, not just
    /// the heading.
    var seerrHeaderRow: Widget!
    /// How many results Seerr has.
    var seerrNumber: Widget!
    var seerrGrid: Widget!
    var sleepMinutes: Int?
    var sleepTick = 0

    // MARK: Libraries
    /// The libraries the server has. **From two of the same kind** the user
    /// chooses between them; with one there is no switcher.
    var review: [Item] = []
    var selectedLibrary: [Region: String] {
        get {
            var d: [Region: String] = [:]
            for (k, v) in selection.libraryPerGenre {
                if let b = Region.allCases.first(where: { $0.identifier == k }) { d[b] = v }
            }
            return d
        }
        set {
            for (b, v) in newValue { selection.libraryPerGenre[b.identifier] = v }
            selection.secure()
        }
    }
    // MARK: Title menu: All, collections, libraries (Mac)
    /// Button, title and arrow of the title menu per section.
    var titleSelection: [Region: (button: Widget, title: Widget, angle: Widget)] = [:]
    /// The account's collections; `nil` until requested.
    var collectionDirectory: CollectionDirectory?
    /// The account's video playlists; `nil` until requested or if the server did not answer.
    var playlistDirectory: PlaylistDirectory?
    /// Movies and series per mixed library.
    var libraryShares: [String: LibraryShare] = [:]
    /// For which account and which libraries both apply.
    var offeringFor: String?
    var offeringRuns: String?
    var offeringTime: Date?
    /// Who is waiting for the running load: the "Teil der Sammlung" row.
    var offeringWaiting: [() -> Void] = []
    /// What a grid page last read from; if that changes with the offer, it
    /// reloads.
    var gridSource: [Region: String] = [:]
    /// After an account switch: grids whose new content arrives staggered.
    var gridSeasons: Set<Region> = []
    /// **Several libraries are filtered** (``TitleFilter``): each title once. Also
    /// how far the server's raw pages have been read.
    var gridFilter: [Region: TitleFilter] = [:]
    /// **"By name" in natural order** (``NaturalOrder``): the whole list, slim, per grid.
    /// Fetched with the first page, read by every later page and by the letter strip.
    var gridNatural: [Region: [Item]] = [:]
    /// The letter strip of a "By name" grid (``AlphabetIndex``).
    var gridAlphabet: [Region: AlphabetIndex] = [:]
    /// The strip widgets and the scrollers they jump in.
    var alphabetStrips: [Region: AlphabetStrip] = [:]
    var gridScrollers: [Region: Widget] = [:]
    /// A letter whose first title is still being loaded; the jump continues with the next page.
    var pendingLetter: [Region: String] = [:]
    var gridRaw: [Region: (offset: Int, total: Int)] = [:]
    /// When the home screen last loaded, for reloading on return to the
    /// foreground.
    var lastLoaded: Date?
    /// **The detail page has two panes, not one.**
    ///
    /// A `GtkStack` animates between *different* children. Clearing and refilling
    /// the same child gives no motion, and that is how it was: it slid from the
    /// home screen to a movie, but not from a movie to the series behind it. Two
    /// panes, filled alternately, turn every step into a switch.
    var detailDiscs: [Widget] = []
    var detailDisc = 0
    var detailWrapper: Widget! { detailDiscs[detailDisc] }
    /// Needed while scrolling to fade the title into the header bar; the same
    /// calculation as `DetailHeader.staerke` on the Mac.
    var detailHeaderTitle: Widget!
    var detailHeaderBar: Widget!
    var detailHeaderHistory: Widget!

    /// **Sidebar left, content right**, the Mac's layout.
    ///
    /// On the Mac the sidebar spans the full window height, the window buttons
    /// float above it, and `Theme.signalHeight` keeps 40 points free at its top. On
    /// Wayland the title bar belongs to the window, not to us; the sidebar
    /// therefore starts below a narrow header row in the sidebar's color. This is
    /// the one deviation that cannot be removed without losing the window buttons.
    private func homePageBuild() -> Widget! {
        let landscape = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        append(landscape, sidebarBuild())

        content = gtk_stack_new()
        // **No cross-fade.** `GtkStack` can only cross-fade, with both sides half
        // visible at once. Section changes therefore go through ``switchStack``:
        // first out, then in.
        gtk_stack_set_transition_type(OpaquePointer(content), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_widget_set_hexpand(content, 1)
        gtk_widget_set_vexpand(content, 1)

        gtk_stack_add_named(OpaquePointer(content), startSectionBuild(), "start")
        gtk_stack_add_named(OpaquePointer(content), gridPageBuild(.movies), "filme")
        gtk_stack_add_named(OpaquePointer(content), gridPageBuild(.seriesList), "serien")
        gtk_stack_add_named(OpaquePointer(content), gridPageBuild(.watchlist), "merkliste")
        gtk_stack_add_named(OpaquePointer(content), gridPageBuild(.collection), "sammlung")
        gtk_stack_add_named(OpaquePointer(content), gridPageBuild(.genre), "gattung")
        gtk_stack_add_named(OpaquePointer(content), downloadsPageBuild(), "downloads")
        gtk_stack_add_named(OpaquePointer(content), searchBuild(), "suche")

        // **The detail page slides over, it does not move beside.**
        //
        // A `GtkStack` slides *both* children by the full width on a switch, which
        // looks as if the pages lay side by side. The Mac slides the new page over
        // the old one, and the one underneath moves only about a third. That needs
        // its own stage.
        //
        // `GtkFixed` is the only GTK container that moves its children freely, and
        // `gtk_fixed_move` only changes the offset, not the size, so the page is not
        // re-wrapped on every frame.
        stage = gtk_fixed_new()
        gtk_widget_set_overflow(stage, GTK_OVERFLOW_HIDDEN)
        gtk_fixed_put(asFixed(stage), content, 0, 0)
        for _ in 0..<2 {
            let disc: Widget! = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_add_css_class(disc, "swiftly-scheibe")
            detailDiscs.append(disc)
            gtk_fixed_put(asFixed(stage), disc, 0, 0)
            gtk_widget_set_visible(disc, 0)
        }
        onTop = content

        // **A `GtkFixed` gives its children their preferred size, not its own**
        // (trap 1). A page is a scroller inside and prefers almost nothing, so it
        // would collapse. Someone has to tell it the size, and someone has to know it
        // first.
        //
        // The drawing area is that someone: as the **main child** of an overlay it
        // always gets the full area, and its `resize` signal reports it. Nothing is
        // drawn on it.
        let sizeInfo: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(sizeInfo, "swiftly-blank")
        gtk_widget_set_hexpand(sizeInfo, 1)
        gtk_widget_set_vexpand(sizeInfo, 1)
        onSize(sizeInfo) { [weak self] width, height in
            guard let self else { return }
            // **Only when something actually changed.**
            //
            // `gtk_widget_set_size_request` queues a new layout even when the same value
            // is set again. The new layout assigns the drawing area a size again, it
            // reports again, and this continues every frame: **a loop that feeds itself.**
            // Measured: 92% constant load already on the sign-in screen, and a window that
            // no longer got to draw.
            guard width != self.stageWidth || height != self.stageHeight else { return }
            self.stageWidth = width
            self.stageHeight = height
            // **Not in the middle of layout.** A request from inside `resize` was
            // sometimes lost when growing, and the new strip stayed black.
            onMainThread {
                guard self.stageWidth == width, self.stageHeight == height else { return }
                for layer in [self.content!] + self.detailDiscs {
                    gtk_widget_set_size_request(layer, width, height)
                }
                gtk_widget_queue_resize(self.stage)
            }
        }

        let frameRect: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(frameRect, 1)
        gtk_widget_set_vexpand(frameRect, 1)
        gtk_overlay_set_child(OpaquePointer(frameRect), sizeInfo)
        gtk_overlay_add_overlay(OpaquePointer(frameRect), stage)
        append(landscape, frameRect)

        titleLine = label("", style: "swiftly-zweitzeile")
        return landscape
    }

    // MARK: Keyboard shortcuts

    /// **The same shortcuts as on the Mac**, with Ctrl instead of Cmd: 1 Home,
    /// 2 Movies, 3 Series, F Search. They are defined in
    /// `Sources/macOS/SwiftlyApp.swift` as `CommandButton`.
    ///
    /// On the Mac they hang in the menu bar; there is none here, so the window
    /// listens itself. `GtkShortcutController` would be the proper way but needs
    /// named actions; for four keys a key listener is less machinery.
    private func keysSetUp() {
        let watcher = gtk_event_controller_key_new()
        // **Capture phase, not bubble phase.**
        //
        // In the bubble phase the focused widget gets the key first. When the player
        // opens, focus is on the first button at the top, and the space bar presses it
        // instead of pausing. Anyone who had clicked somewhere before did not see the
        // bug.
        //
        // The same trap as with scrolling, solved the same way. The callback passes
        // unhandled keys on, so nothing is lost: typing in the search field works as
        // before.
        gtk_event_controller_set_propagation_phase(watcher, GTK_PHASE_CAPTURE)
        g_signal_connect_data(UnsafeMutableRawPointer(watcher), "key-pressed",
                              unsafeBitCast(keyPressed, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(window, watcher)
    }

    /// True means consumed, do not pass on.
    func keyButton(_ value: UInt32, ctrl: Bool) -> Bool {
        // A support dialog on top of the window takes Escape before anything else.
        if value == 0xFF1B, supportEscape() { return true }
        if value == 0xFF1B, panelWindowEscape() { return true }
        // **The shortcuts under the buttons must be right.**
        //
        // Under the player's three buttons stand "←", "Leertaste" and "→", and they
        // stood there without any of those keys doing anything. A hint that is wrong
        // is worse than none.
        //
        // The same four as on the Mac (`PlayerScreen`), without a modifier: space
        // pauses, the arrows seek, F toggles fullscreen, Escape leaves fullscreen first
        // and then the player.
        if runningTitle != nil, !ctrl {
            switch value {
            // **With a layer open the keys belong to it**, the same rule as on the Mac
            // (`PlayerScreen.escapeKey` environment): space and arrows must not control
            // playback while a fullscreen layer is open. Escape is unaffected; see below.
            case 0x020 where openLayer == nil:           // Space
                playToggle()
                return true
            case 0xFF51 where openLayer == nil:          // Left arrow
                vault(um: -Double(selection.backSeconds))
                playerBackCharacter?.nudge()
                jumpShow(true)
                controlsShow()
                return true
            case 0xFF53 where openLayer == nil:          // Right arrow
                vault(um: Double(selection.forwardSeconds))
                playerPreCharacter?.nudge()
                jumpShow(false)
                controlsShow()
                return true
            // **Delay as in VLC and on the Mac:** G/H subtitles, J/K audio, 50 ms each.
            // Not with a layer open: the row itself is shown there, and its display would
            // not know about the key press.
            case 0x067, 0x047, 0x068, 0x048,               // g G h H
                 0x06A, 0x04A, 0x06B, 0x04B:               // j J k K
                guard openLayer == nil else { return false }
                let small = value | 0x20
                postpone(subtitle: small == 0x067 || small == 0x068,
                           small == 0x067 || small == 0x06A ? -1 : 1)
                return true
            case 0xFFC8, 0x066, 0x046:                     // F11, f, F
                // **F as on the Mac** (`PlayerScreen`, `.keyboardShortcut("f")`), without a
                // modifier and also with a layer open, where it has no other meaning. F11 is
                // the way GTK users know.
                fullscreenToggle()
                return true
            // **M as in every player** toggles mute; without a key there was no way
            // to do it.
            case 0x06D where openLayer == nil, 0x04D where openLayer == nil:
                mutedToggle()
                volumeShortShow()
                return true
            // **Volume as on the Mac:** up and down arrows, +/-5%.
            case 0xFF52 where openLayer == nil:          // Up arrow
                volumeLevel(0.05)
                return true
            case 0xFF54 where openLayer == nil:          // Down arrow
                volumeLevel(-0.05)
                return true
            case 0xFF0D, 0xFF8D:                           // Enter, numeric keypad
                // **While the overlay is shown, Enter triggers it**, without focus, as on
                // the Mac (`PlayerScreen`, `.keyboardShortcut(.return)`). Otherwise the key
                // goes on to the focused button.
                guard offeringImage else { return false }
                offeringRun()
                return true
            case 0xFF1B:                                   // Escape
                // **First the panel, then the overlay, then fullscreen, then the player.**
                // The Mac checks the open track picker before anything else
                // (`PlayerScreen.escapeKey()`); the overlay closes only itself and the movie
                // keeps playing.
                if openLayer != nil {
                    layerClose()
                } else if offeringImage {
                    offeringLayer.close()
                    offeringUpdate()
                    AppLog.writeOut("[Angebot] geschlossen (Escape), weiter abgesagt: \(offeringLayer.nextCancelled)")
                    fflush(nil)
                } else if gtk_window_is_fullscreen(asWindow(window)) != 0 {
                    gtk_window_unfullscreen(asWindow(window))
                } else {
                    playerClose()
                }
                return true
            default: break
            }
        }
        guard ctrl else { return false }
        // GDK's key values are the ASCII characters; Swift has no names for them
        // because in GDK they are macros.
        switch value {
        case 0x031: show(.start)                          // 1
        case 0x032: show(.movies)                          // 2
        case 0x033: show(.seriesList)                         // 3
        case 0x066, 0x046:                                 // f / F
            show(.search)
            gtk_widget_grab_focus(searchField)
        case 0x05B:                                        // [
            // **Back**: the Mac has it as Cmd+[ in the "Gehe zu" menu
            // (`SwiftlyApp.swift`). Without it, the arrow is the only way back from a
            // subpage.
            back()
        // **The two shortcuts every desktop app has** (GNOME HIG): Ctrl+, opens the
        // settings like Cmd+, on the Mac, Ctrl+Q quits. Not in the player, where the
        // page would lie behind the movie.
        case 0x02C where runningTitle == nil && client != nil: // ,
            subpageOpen(.settings)
        case 0x071, 0x051:                                 // q / Q
            // Via `close-request`, not a hard exit: a running movie still reports its
            // position, and the window size is stored.
            gtk_window_close(asWindow(window))
        default: return false
        }
        return true
    }

    // MARK: Header bar

    /// **The header bar stays empty.**
    ///
    /// Server name and "Abmelden" were here while there was no sidebar. On the Mac
    /// both are at the bottom left in the account row, and they moved there. The
    /// bar itself must stay: on Wayland the window buttons hang on it, and without
    /// it the window could no longer be closed.
    private func headerRowFill() {
        gtk_header_bar_set_title_widget(OpaquePointer(headerLine), titleLine)
        headerRowShow(false)
    }

    private func headerRowShow(_ visible: Bool) {
        gtk_widget_set_visible(titleLine, visible ? 1 : 0)
    }

    // MARK: Sidebar

    private func sidebarBuild() -> Widget! {
        let bar = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(bar, "swiftly-seitenleiste")
        gtk_widget_set_size_request(bar, Int32(Theme.sidebarWidth), -1)
        gtk_widget_set_hexpand(bar, 0)

        // Logo: 28 high, 20 on the sides, 18 below; from MainView.swift.
        let mark = Theme.wordmark(height: 28, left: true)
        gtk_widget_set_margin_start(mark, 20)
        gtk_widget_set_margin_end(mark, 20)
        gtk_widget_set_margin_top(mark, 14)
        gtk_widget_set_margin_bottom(mark, 18)
        append(bar, mark)

        // The four sections, 2 spacing, 12 on the sides.
        let areas = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_margin_start(areas, 12)
        gtk_widget_set_margin_end(areas, 12)
        for fall in Region.topGroup { append(areas, sectionRow(fall)) }
        append(bar, areas)

        // **Below that, what belongs to the user.** The reasoning is at
        // `Region.mineGroup`; the measurements are those of the library group,
        // since it is the same kind of subheading.
        mineCategory = category(translated("Meins"))
        gtk_widget_set_margin_top(mineCategory, 26)
        gtk_widget_set_margin_bottom(mineCategory, 8)
        gtk_widget_set_margin_start(mineCategory, 12)
        gtk_widget_set_margin_end(mineCategory, 12)
        append(bar, mineCategory)

        myList = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_margin_start(myList, 12)
        gtk_widget_set_margin_end(myList, 12)
        append(bar, myList)
        mineFill()

        // **No "Bibliotheken" group any more** (Mac). The other libraries used to
        // open here as their own root; now they are in the title menu of Movies and
        // Series: one path instead of two, and one that does not leave the section.

        append(bar, padding())
        // **What is playing on another device sits next to the account.**
        //
        // Exactly where the user already looks, the same place as the badge on iPhone
        // and TV, in the form of this sidebar (`macOS/MainView.swift`). It only
        // becomes visible when there is actually something to take over.
        takeoverRow = takeoverRowBuild()
        gtk_widget_set_visible(takeoverRow, 0)
        append(bar, takeoverRow)
        append(bar, divider())
        append(bar, profileRowBuild())
        return bar
    }

    /// A row in the bar, stored under its section.
    private func sectionRow(_ fall: Region) -> Widget! {
        let row = sidebarRow(symbol: fall.symbol,
                                       text: fall.label,
                                       active: fall == section)
        // **The shortcut sits on the tooltip.**
        //
        // On the Mac all five are visible in the menu bar under "Gehe zu"
        // (`SwiftlyApp.swift`). That does not exist here (a Wayland window has none),
        // and the shortcuts worked but could be read nowhere. A tooltip is where a UI
        // without a menu says such things.
        if let abbreviation = fall.abbreviation {
            gtk_widget_set_tooltip_text(row, "\(fall.label)   \(abbreviation)")
        }
        signal(row, "clicked") { [weak self] in self?.show(fall) }
        sectionButtons[fall] = row
        return row
    }

    /// **The "Meins" group is rebuilt when the switch is toggled.**
    /// Without downloads the row does not exist, and whoever turns it off while
    /// standing on it must not stay on a page that no longer exists.
    func mineFill() {
        guard myList != nil else { return }
        wipe(myList)
        let mine = Region.mineGroup(downloads: downloadsAn, watchlist: selection.watchlistShown)
        for fall in mine {
            append(myList, sectionRow(fall))
        }
        gtk_widget_set_visible(mineCategory, mine.isEmpty ? 0 : 1)
        if !downloadsAn {
            sectionButtons[.downloads] = nil
            if section == .downloads { show(.start) }
        }
        if !selection.watchlistShown {
            sectionButtons[.watchlist] = nil
            if section == .watchlist { show(.start) }
        }
    }

    /// Who is signed in, and where. At the bottom of the sidebar: 40 high, picture
    /// 26, name 14 semibold, server 11 very quiet.
    /// The "Hier weiterschauen" row.
    ///
    /// **Measured exactly from the Mac** (`Macbausteine.Uebernahmezeile`): 40 high,
    /// a capsule like the badge on the TV: 14 inside, glyph 20 wide and title in
    /// the accent, below it title and episode in 11 on very quiet text. Accent at
    /// 18% over `reason`, floating white 6% on top.
    ///
    /// The title used to be on top with "läuft auf iPhone" below. That says
    /// **what** is playing; the Mac says **what can be done** and puts the title
    /// below. With one offer that is the right order.
    private func takeoverRowBuild() -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-uebernahme")
        // **One inset on every side the badge touches** (macOS `abzeichenRand`). The bottom used to be 4 against 12 at the sides.
        // The card grows from the middle of this row (`handoffStart`) and follows it automatically.
        gtk_widget_set_margin_start(button, Theme.badgeEdge)
        gtk_widget_set_margin_end(button, Theme.badgeEdge)
        gtk_widget_set_margin_bottom(button, Theme.badgeEdge)

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        takeoverCharacter = gtk_image_new_from_icon_name("phone-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(takeoverCharacter), 13)
        gtk_widget_set_size_request(takeoverCharacter, 20, -1)
        append(rail, takeoverCharacter)

        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let top = label(translated("Hier weiterschauen"), style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(top), 0)
        gtk_label_set_ellipsize(OpaquePointer(top), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(top), 1)
        append(text, top)
        takeoverTop = top
        takeoverTitle = label("", style: "swiftly-uebernahmezeile")
        gtk_label_set_xalign(OpaquePointer(takeoverTitle), 0)
        gtk_label_set_ellipsize(OpaquePointer(takeoverTitle), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(takeoverTitle), 1)
        append(text, takeoverTitle)
        gtk_widget_set_hexpand(text, 1)
        append(rail, text)

        // **One badge for everything playing elsewhere** (iOS `OfferingBadge`): if something plays elsewhere **and** there is a group, a counter sits on it. No second row next to it.
        let counter = label("", style: "swiftly-zaehler")
        gtk_widget_set_valign(counter, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(counter, 0)
        append(rail, counter)
        takeoverCounter = counter

        gtk_button_set_child(asButton(button), rail)
        signal(button, "clicked") { [weak self] in self?.takeoverPressed() }
        caption(button, translated("Wiedergabe übernehmen"))
        return button
    }

    /// **Which icon for which device.** Which device it is is decided in the package; here only Adwaita's icon name is chosen.
    func devicesCharacter(_ art: RemoteSession.DevicesKind) -> String {
        switch art {
        case .phone:   "phone-symbolic"
        case .tablet:    "tablet-symbolic"
        case .computer:   "computer-symbolic"
        case .tv: "video-display-symbolic"
        case .unknown: "media-playback-start-symbolic"
        }
    }

    /// **Polls regularly for what is playing elsewhere.**
    ///
    /// A timer rather than a single look: the other session may start while this app is already open, and an offer that only appears after the next launch is no offer.
    ///
    /// **Five seconds, not ten.** This looks for a session that did **not exist** before, and such a session reports immediately, so the wait came entirely from this number (`Sources/Shared/TakeoverModel.swift:46-60`).
    func takeoverTickStart() {
        takeoverRun?.cancel()
        takeoverRun = Task.detached { [self] in
            while !Task.isCancelled {
                await self.takeoverAsk()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func takeoverAsk() async {
        guard let client, !userIdentifier.isEmpty else { return }
        // **Quiet outside, loud in the log.** Polling is periodic, so a message on the home page would be noise. But the difference between "nothing is playing" and "the query failed" must be visible somewhere: `remoteSession()` used to return every failure as an empty list, which made the handover hard to debug.
        let sessions: [RemoteSession]
        do {
            sessions = try await client.remoteSession()
        } catch {
            TrackSupport.sag("[Uebernahme] Abfrage fehlgeschlagen: \(error)")
            return
        }
        // After a server restart nobody could reach this session (see `PlayTargets.mustReport`).
        if PlayTargets.mustReport(sessions, ownDevicesIdentifier: Device.identifier) {
            AppLog.writeOut("[Abspielen auf] eigene Sitzung fehlt, Fähigkeiten neu gemeldet")
            try? await client.reportCapabilities()
        }
        let offerings = Takeover.offerings(from: sessions,
                                           ownDevicesIdentifier: Device.identifier,
                                           ownUserIdentifier: userIdentifier)
        onMainThread {
            self.takeoverOfferings = offerings
            self.takeoverShow()
            // **The same answer feeds "Übergeben an …"**: a second timer asking the
            // same question would double the requests for nothing.
            self.playTargetsTake(sessions)
        }
    }

    func takeoverShow() {
        guard let row = takeoverRow else { return }
        // **Not while something plays here.** Otherwise the offer would invite the user to interrupt themselves.
        // An error stays in the row for a few seconds; the next poll must not overwrite it immediately.
        guard Date() >= takeoverErrorUntil else { return }
        let devices = takeoverOfferings.filter { $0.running != nil }
        let groups = sharedOfferings
        let count = devices.count + groups.count
        guard runningTitle == nil, count > 0 else {
            gtk_widget_set_visible(row, 0)
            return
        }
        // Wording and icon as in `OfferingBadge` on iOS.
        let top = count > 1 ? translated("Läuft gerade")
            : devices.isEmpty ? translated("Gemeinsam schauen") : translated("Hier weiterschauen")
        gtk_label_set_text(OpaquePointer(takeoverTop), top)
        gtk_label_set_text(OpaquePointer(takeoverTitle),
                           (devices.map(\.titleLine) + groups.map(\.name)).joined(separator: ", "))
        gtk_image_set_from_icon_name(OpaquePointer(takeoverCharacter),
                                     devices.first.map { devicesCharacter($0.devicesKind) }
                                         ?? "system-users-symbolic")
        gtk_label_set_text(OpaquePointer(takeoverCounter), "\(count)")
        gtk_widget_set_visible(takeoverCounter, count > 1 ? 1 : 0)
        caption(row, top)
        gtk_widget_set_visible(row, 1)
    }

    /// **End there first, then start here**, and do not swallow the error. If it keeps playing there while the same starts here, two audio tracks play and nobody knows why.
    ///
    /// **End, do not pause.** Paused, the connection stays open, the session stays listed, and the player still covers the other device. The position is read beforehand, so it is not lost.
    ///
    /// **With several devices, ask instead of guessing.** The choice appears where the click happened, as on macOS (`MainView.badgePressed`, `Uebernahmeauswahl`).
    private func takeoverPressed() {
        let offerings = takeoverOfferings.filter { $0.running != nil }
        // **With groups**: a single one opens "Beitreten" directly, otherwise the panel offers both (iOS `OfferingBadge.tapOn`).
        let groups = sharedOfferings
        if let g = groups.first {
            if offerings.isEmpty, groups.count == 1 {
                sharedJoinShow(g, an: takeoverRow)
            } else {
                sharedSelectionShow(devices: offerings, groups: groups, an: takeoverRow)
            }
            return
        }
        if offerings.count > 1 {
            takeoverSelectionShow(offerings)
        } else if let a = offerings.first {
            adopt(a)
        }
    }

    #if DEBUG
    /// Remote-control desk `takeover`, see there.
    func takeoverProbe(_ choice: Int?) {
        let episode = lastStartRail.first
        takeoverOfferings = ["Probe-Telefon", "Probe-Fernseher"].enumerated().map { i, name in
            RemoteSession(id: "probe-\(i)", devicesIdentifier: "probe-\(i)", deviceName: name,
                         program: "Swiftly", takesCommands: true, running: episode,
                         state: nil)
        }
        takeoverErrorUntil = .distantPast
        takeoverShow()
        if let choice, takeoverOfferings.indices.contains(choice - 1) {
            adopt(takeoverOfferings[choice - 1])
        } else {
            takeoverPressed()
        }
    }
    #endif

    private func takeoverSelectionShow(_ offerings: [RemoteSession]) {
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_size_request(list, 300, -1)
        let header = label(translated("Wo weiterschauen?"), style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(header), 0)
        gtk_widget_set_margin_start(header, 10)
        gtk_widget_set_margin_top(header, 6)
        append(list, header)
        let hint = label(
            translated("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter."),
            style: "swiftly-uebernahmezeile", wrap: true)
        gtk_label_set_xalign(OpaquePointer(hint), 0)
        gtk_widget_set_margin_start(hint, 10)
        gtk_widget_set_margin_end(hint, 10)
        gtk_widget_set_margin_bottom(hint, 6)
        append(list, hint)

        let panel = panelOpen(an: takeoverRow)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
        for session in offerings {
            let device = session.deviceName ?? translated("Gerät")
            let spot = PlayTime.text(session.state?.spot ?? 0)
            append(list, actionRow(devicesCharacter(session.devicesKind),
                                            "\(device) · \(session.titleLine) · \(spot)") {
                [weak self] in
                gtk_popover_popdown(asPanel(panel))
                self?.adopt(session)
            })
        }
        AppLog.writeOut("[Uebernahme] Auswahl mit \(offerings.count) Geraeten")
        fflush(nil)
        gtk_popover_popup(asPanel(panel))
    }

    /// **The card grows out of the row immediately**, as on macOS; the player opens beneath it without a fade (`handoffStart(title:)`).
    /// **Notice first, then stop**: this tells the sender that its stop is a handover. Then the row waits at most 1.5 seconds for the position the sender reports on stopping (Apple `TakeoverModel.wish`).
    func adopt(_ session: RemoteSession) {
        guard let client, let title = session.running else { return }
        handoffStart(title: title)
        gtk_widget_set_visible(takeoverRow, 0)
        Task.detached { [self] in
            let before = (try? await client.item(id: title.id))?.userData?.playbackPositionTicks
            let freshValue = (try? await client.remoteSession())?.first { $0.id == session.id }?.state?.spot
            let sessionPoint = freshValue ?? session.state?.spot ?? 0
            if Takeover.takesHint(session) {
                do { try await client.handoffHint(an: session.id, device: App.handoffName) }
                catch { AppLog.writeOut("[Uebergabe] Hinweis nicht gesendet: \(error)") }
            }
            do { try await client.foreignCommand(.finish, an: session.id) }
            catch {
                let text = readableError(error)
                AppLog.writeOut("[Uebernahme] Beenden auf \(session.deviceName ?? session.id) gescheitert: \(text)")
                fflush(nil)
                onMainThread {
                    self.handoffCancel("Stopp abgelehnt")
                    // **Where the click happened.** The message used to go into a field on the login screen that nobody sees here.
                    self.takeoverOfferings = []
                    self.takeoverErrorUntil = Date().addingTimeInterval(6)
                    gtk_label_set_text(OpaquePointer(self.takeoverTitle), text)
                    gtk_widget_set_visible(self.takeoverRow, 1)
                }
                return
            }
            // In steps of 100 ms: each oversleeping step delays the start.
            var afterwards: Int64?
            for _ in 0 ..< 15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let now = (try? await client.item(id: title.id))?.userData?.playbackPositionTicks
                if now != before { afterwards = now; break }
            }
            let since = Takeover.startPoint(session: sessionPoint, savedBefore: before,
                                            savedAfterwards: afterwards)
            AppLog.writeOut("[Uebernahme] Sitzung \(Int(sessionPoint)) s, nach Stopp "
                + "\(afterwards.map { String(Int(Double($0) / 10_000_000)) } ?? "—") s → ab \(Int(since)) s")
            onMainThread {
                self.takeoverOfferings = []
                self.handoffPlayerComes(title.id)
                self.launch(title, since: since)
            }
        }
    }

    private func profileRowBuild() -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-profil")
        // **It carries the highlight while a subpage is open.** On macOS `ProfileRow` gets `active: inAccount` and colours name and surface with the accent. Here `bereichszeilenMalen` removed the highlight from all area rows once a subpage was open but passed it on nowhere, so nothing was highlighted.
        profileRow = button
        edges(button, 12)

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)

        // **With several accounts the zone holds several circles**, so it is refilled on every login instead of keeping a fixed image. `profileCircleRefresh()` builds it.
        profileCircle = gtk_fixed_new()
        gtk_widget_set_valign(profileCircle, GTK_ALIGN_CENTER)
        append(rail, profileCircle)

        let names = stack(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_valign(names, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(names, 1)
        profileName = label("—", style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(profileName), 0)
        gtk_label_set_ellipsize(OpaquePointer(profileName), PANGO_ELLIPSIZE_END)
        append(names, profileName)
        profileServer = label("", style: "swiftly-rubrik")
        gtk_widget_add_css_class(profileServer, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(profileServer), 0)
        gtk_label_set_ellipsize(OpaquePointer(profileServer), PANGO_ELLIPSIZE_END)
        append(names, profileServer)
        append(rail, names)

        gtk_button_set_child(asButton(button), rail)
        // On macOS the row leads to the profile; "Abmelden" is one level deeper there.
        signal(button, "clicked") { [weak self] in self?.subpageOpen(.profile) }
        return button
    }

    /// How a page changes place.
    ///
    /// On macOS this is `Theme.timePagesPush`: `easeInOut`, 0.45 s, with the rule that going deeper pushes in from the right and going back pushes out to the right. An area switch instead cross-fades ("fade through"), because it does not go deeper but sideways. **`fade` is the area switch**, `deeper`/`back` is paging through titles, `without` is rebuilding in place.
    ///
    /// It exists because the same click had two behaviours: an area without a remembered detail page got the stack's cross-fade, one with a remembered page got `shove(.without)`, i.e. nothing.
    enum Push { case deeper, back, without, fade }

    /// Puts a layer on top and pushes it in.
    ///
    /// As on macOS: `Theme.timePagesPush`, `easeInOut`, 0.45 s. The new page covers the old one; the old one moves **a little under a third** to the left and stays. Going back runs in reverse: the top page slides out to the right and reveals the one beneath.
    ///
    /// The order in the `GtkFixed` decides which covers which: when pushing forward the new layer must be on top, when pushing back the old one, because it is the one that moves.
    func shove(toward target: Widget!, bearing wished: Push) {
        // **With reduced motion nothing slides**; the page briefly cross-fades, as on Apple, where "Reduce Motion" replaces every transition with a fade. The fade below reads the setting itself and then uses `Theme.timeReduced`.
        let bearing: Push = motionReduced() && (wished == .deeper || wished == .back)
            ? .fade : wished
        let alt: Widget! = onTop
        onTop = target
        gtk_widget_set_visible(target, 1)
        guard alt != target else { return }

        let fixed = asFixed(stage)
        let width = Double(gtk_widget_get_width(stage))

        // **Out first, then in, never both at once.** The old page leaves briefly with `easeIn`, and only when it is gone does the new one arrive with `easeOut` (`FadeTimes.pagesSwitch`, same as macOS). A cross-fade would show two half-visible pages on top of each other in the middle.
        if bearing == .fade {
            gtk_fixed_move(fixed, target, 0, 0)
            gtk_widget_insert_before(target, stage, nil)
            gtk_widget_set_opacity(target, 0)
            // With reduced motion short and linear (macOS `Theme.linearReduced`), likewise one after the other.
            let reduced = motionReduced()
            let total = reduced ? 2 * Theme.timeReduced : FadeTimes.pageTotal
            runningCount(on: stage, duration: total, linear: true) { e in
                if reduced {
                    gtk_widget_set_opacity(alt, max(0, 1 - 2 * e))
                    gtk_widget_set_opacity(target, max(0, 2 * e - 1))
                } else {
                    let d = FadeTimes.pagesSwitch(e * total)
                    gtk_widget_set_opacity(alt, d.alt)
                    gtk_widget_set_opacity(target, d.new)
                }
            } done: {
                gtk_widget_set_opacity(target, 1)
                gtk_widget_set_opacity(alt, 1)
                gtk_widget_set_visible(alt, 0)
            }
            return
        }

        guard bearing != .without, width > 1 else {
            gtk_fixed_move(fixed, target, 0, 0)
            gtk_widget_set_visible(alt, 0)
            return
        }

        gtk_widget_insert_before(bearing == .deeper ? target : alt, stage, nil)
        PushLock.begin()
        let divider = Scaling.devicesPoints(stage)
        // Rounded to whole device points, for the same reason as when scrolling: an edge on a half point is smoothed and shows a fringe.
        func latch(_ x: Double) -> Double { (x * divider).rounded() / divider }

        runningCount(on: stage, duration: Theme.timePagesPush) { e in
            if bearing == .deeper {
                gtk_fixed_move(fixed, target, latch(width * (1 - e)), 0)
                gtk_fixed_move(fixed, alt, latch(-width * Theme.pushWithGift * e), 0)
                gtk_widget_set_opacity(alt, 1 - Theme.pushScrim * e)
            } else {
                gtk_fixed_move(fixed, alt, latch(width * e), 0)
                gtk_fixed_move(fixed, target, latch(-width * Theme.pushWithGift * (1 - e)), 0)
                gtk_widget_set_opacity(target, 1 - Theme.pushScrim * (1 - e))
            }
        } done: {
            gtk_fixed_move(fixed, target, 0, 0)
            gtk_fixed_move(fixed, alt, 0, 0)
            gtk_widget_set_opacity(target, 1)
            gtk_widget_set_opacity(alt, 1)
            gtk_widget_set_visible(alt, 0)
            PushLock.finish()
        }
    }

    /// Shows an area: faded in sequence in the stack, pushed on the stage.
    ///
    /// If the stack is already on top, it switches in place (`switchStack`). If a detail page lies above, `shove(toward:bearing:)` fades it out and the stack in; the stack itself already stands on the new area.
    func sectionShow(_ identifier: String, push: Push) {
        if onTop == content, push == .fade {
            switchStack(content, toward: identifier)
            return
        }
        stackSwitchCancel(content)
        gtk_stack_set_visible_child_name(OpaquePointer(content), identifier)
        shove(toward: content, bearing: push)
    }

    /// **A stack switches in sequence, not cross-faded**: first the old page leaves (`easeIn`), then the new one arrives (`easeOut`), with the times from `FadeTimes`, same as macOS.
    ///
    /// The swap hangs on a deadline, not on the end of the fade: the frame clock stops when the window is not drawing, and the page should switch anyway. A second switch in the middle of the first wins.
    func switchStack(_ stackW: Widget!, toward identifier: String) {
        guard let stackW else { return }
        let st = OpaquePointer(stackW)
        gtk_stack_set_transition_type(st, GTK_STACK_TRANSITION_TYPE_NONE)
        let key = UnsafeMutableRawPointer(stackW)
        let running = stackSwitch[key] != nil
        if !running, let now = gtk_stack_get_visible_child_name(st),
           String(cString: now) == identifier { return }
        guard gtk_widget_get_mapped(stackW) != 0 else {
            stackSwitchCancel(stackW)
            gtk_stack_set_visible_child_name(st, identifier)
            return
        }
        stackSwitchCounter += 1
        let number = stackSwitchCounter
        stackSwitch[key] = number
        let reduced = motionReduced()
        let out = reduced ? Theme.timeReduced : FadeTimes.pageToOut
        crossfade(stackW, on: 0, duration: out, curve: .easeIn)
        let container = held(stackW)
        postDeadline(out) { [weak self] in
            defer { letGo(container) }
            guard let self, self.stackSwitch[key] == number, let w = container.widget else { return }
            self.stackSwitch[key] = nil
            gtk_stack_set_visible_child_name(OpaquePointer(w), identifier)
            crossfade(w, on: 1, duration: FadeTimes.pageFromIn, curve: .easeOut)
        }
    }

    /// A running `switchStack` no longer applies: whoever changes the stack themselves now must not have it overwritten a deadline later.
    func stackSwitchCancel(_ stackW: Widget!) {
        guard let stackW else { return }
        let key = UnsafeMutableRawPointer(stackW)
        guard stackSwitch.removeValue(forKey: key) != nil else { return }
        crossfade(stackW, on: 1, duration: 0)
    }

    /// Takes the free detail pane and empties it.
    func nextDisc() -> Widget! {
        detailDisc = 1 - detailDisc
        wipe(detailWrapper)
        return detailWrapper
    }

    /// Switches the area and recolours the rows.
    ///
    /// **A click on the open area leads to its root.** `show(.start)` used to set `section` to the value it already had, saw a detail page on top of the stack and showed that again, so clicking "Start" from inside a title stayed in the title. macOS fixes the same case in `sectionSelect`.
    ///
    /// A click on a **different** area leaves its stack alone: switching between movies and series returns to where the user was.
    func show(_ new: Region) {
        let alreadyHere = section == new && openSubpage == nil
        // **It also closes an open subpage.** Profile, settings and playback lie above the area, not beside it.
        let outSubpage = openSubpage != nil
        openSubpage = nil
        if alreadyHere { pagesStack[new] = [] }

        // **An area closes the open collection**; on macOS it lives in the stack of its area and goes with it.
        if new != .collection { openCollection = nil }
        _ = outSubpage
        section = new
        sectionRowsDraw()
        // **The stack decides what is shown.** If this area has a detail page on top, it comes back, not the list.
        // **An area switch fades, on both paths.** Only one path used to, because the other went through `shove(.without)`.
        // The page of a downloaded series sits as a marker on the downloads stack; `detailShow` would take it for a server title (`DownloadSeriesOverviewPage.swift`).
        if let top = pagesStack[new]?.last, top.type == App.downloadSeriesArt {
            downloadSeriesShow(top, push: .fade)
        } else if let top = pagesStack[new]?.last {
            detailShow(top, push: .fade)
        } else {
            sectionShow(new.identifier, push: .fade)
        }
        // **Whoever goes to "Suche" wants to type.** macOS sets the focus when the page appears; here it only worked via Ctrl+F.
        if new == .search { gtk_widget_grab_focus(searchField); searchHistoryShow() }
        // **Each area loads once.** On macOS the state of each area is kept, so switching between movies and series only waits the first time.
        guard !loaded.contains(new) else { return }
        loaded.insert(new)
        switch new {
        case .start:  homeLoad()
        case .movies:  gridLoad(.movies)
        case .seriesList: gridLoad(.seriesList)
        case .watchlist: gridLoad(.watchlist)
        // The download list lives on disk; it is shown, not fetched.
        case .downloads: downloadsPageFill()
        case .collection: gridLoad(.collection)
        case .genre: gridLoad(.genre)
        case .search:  break
        }
    }

    // MARK: Content pages

    /// The common frame of every page: 52 at the top, 24 at the sides (`contentTop` and `edgeSpacing` from macOS).
    func pagesFrame(_ kind: Widget!) -> Widget! {
        let scroller = pagesScroller()
        gtk_widget_set_margin_top(kind, Int32(Theme.contentTop))
        gtk_widget_set_margin_start(kind, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(kind, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_bottom(kind, Int32(Theme.edgeSpacing))
        gtk_scrolled_window_set_child(OpaquePointer(scroller), lookGlowWrapped(kind))
        return scroller
    }

    /// **The hairline that fades in on scroll.**
    ///
    /// The grid pages were the only ones without it; the series page has it (`SeriesPage.swift:61`). Without it, content scrolls under the header with no edge and the user cannot see there is more above.
    ///
    /// It is an overlay **above** the scroller, not inside it; inside the content it would scroll along.
    private func withHeaderLine(_ scroller: Widget!) -> Widget! {
        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), scroller)

        let line: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(line, "swiftly-trennlinie")
        gtk_widget_set_size_request(line, -1, 1)
        gtk_widget_set_valign(line, GTK_ALIGN_START)
        gtk_widget_set_opacity(line, 0)
        gtk_widget_set_can_target(line, 0)
        gtk_overlay_add_overlay(OpaquePointer(over), line)

        guard let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
        else { return over }
        // Fades in over the first 24 points, the same short distance as the detail header, so it does not read as movement.
        signalRaw(UnsafeMutableRawPointer(adjustment), "value-changed") {
            let value = gtk_adjustment_get_value(adjustment)
            gtk_widget_set_opacity(line, min(max(value / 24, 0), 1))
        }
        return over
    }

    /// **The bar that appears on scroll, on a library page** (`Bestandsleiste` on macOS).
    ///
    /// The large title scrolls away with the content, the small one fades into a 40-high bar; the two are never visible together. The background appears only with the scroll distance, then the hairline; at rest nothing is there.
    ///
    /// **It hangs on opacity, never on height:** the bar keeps its height and lies as an overlay above the scroller, only its visibility is measured. A layout cannot feed back from that. The same applies to the value row: it fades out over 44 points (`valueRailsDistance`), its height stays.
    ///
    /// **The back button lives in the bar** and does not fade in; an exit that only exists after some scrolling is none.
    func stateBar(_ scroller: Widget!, title: String, back: (() -> Void)? = nil,
                        valueSeries: Widget? = nil) -> (wrapper: Widget, title: Widget) {
        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), scroller)

        let reason: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(reason, "swiftly-bestandsgrund")
        gtk_widget_set_size_request(reason, -1, Int32(Theme.headerBarHeight))
        gtk_widget_set_valign(reason, GTK_ALIGN_START)
        gtk_widget_set_opacity(reason, 0)
        gtk_widget_set_can_target(reason, 0)
        gtk_overlay_add_overlay(OpaquePointer(over), reason)

        let small = label(title, style: "swiftly-leistentitel")
        gtk_label_set_xalign(OpaquePointer(small), 0)
        gtk_label_set_ellipsize(OpaquePointer(small), PANGO_ELLIPSIZE_END)
        gtk_widget_set_size_request(small, -1, Int32(Theme.headerBarHeight))
        gtk_widget_set_valign(small, GTK_ALIGN_START)
        gtk_widget_set_halign(small, GTK_ALIGN_FILL)
        // With arrow: 16 + 40 + 4, like `HStack(spacing: 4)` with the `BackArrow` inset by 8.
        gtk_widget_set_margin_start(small, Int32(back == nil ? Theme.edgeSpacing
                                                                : Theme.edgeSpacing - 8 + 44))
        gtk_widget_set_margin_end(small, Int32(Theme.edgeSpacing))
        gtk_widget_set_opacity(small, 0)
        gtk_widget_set_can_target(small, 0)
        gtk_overlay_add_overlay(OpaquePointer(over), small)

        if let back {
            let arrow: Widget! = gtk_button_new()
            gtk_widget_add_css_class(arrow, "swiftly-zurueck")
            caption(arrow, translated("Zurück"))
            gtk_button_set_child(asButton(arrow),
                                 gtk_image_new_from_icon_name("go-previous-symbolic"))
            gtk_widget_set_size_request(arrow, 40, 40)
            gtk_widget_set_halign(arrow, GTK_ALIGN_START)
            gtk_widget_set_valign(arrow, GTK_ALIGN_START)
            gtk_widget_set_margin_start(arrow, Int32(Theme.edgeSpacing - 8))
            signal(arrow, "clicked", back)
            gtk_overlay_add_overlay(OpaquePointer(over), arrow)
        }

        guard let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
        else { return (over, small!) }
        // **Start point, derived rather than guessed.** The large title (28 bold, about 33 high) starts `contentTop` below the top edge; its bottom edge reaches the bar's at `contentTop + 33 − 40`. The bar fades in over the next 26 points.
        let since = Double(max(Theme.contentTop + 33 - Theme.headerBarHeight, 0))
        let rail = valueSeries.map { held($0) }
        signalRaw(UnsafeMutableRawPointer(adjustment), "value-changed") {
            let value = gtk_adjustment_get_value(adjustment)
            let strength = min(max((value - since) / 26, 0), 1)
            gtk_widget_set_opacity(reason, strength)
            gtk_widget_set_opacity(small, strength)
            if let w = rail?.widget {
                let present = 1 - min(max(value / Theme.valueRailsDistance, 0), 1)
                gtk_widget_set_opacity(w, present)
                gtk_widget_set_can_target(w, present > 0.05 ? 1 : 0)
            }
        }
        if let rail { signal(over, "destroy") { letGo(rail) } }
        return (over, small!)
    }

    /// **A picker button instead of a chip row** (`Wahlknopf`, macOS).
    ///
    /// The button shows the **chosen value**; the options are in the panel below. When open it shows the rotated chevron and the raised surface.
    ///
    /// **At most one open at a time:** the panel is a self-closing `GtkPopover`, so a click elsewhere, even on the neighbouring button, closes it and does nothing else. This is the behaviour of `SelectionSupervision`.
    func selectionButton(symbolText: Widget, value: String,
                   entries: [(text: String, selected: Bool, perform: () -> Void)]) -> Widget! {
        let angle: Widget! = gtk_image_new_from_icon_name("pan-up-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(angle), 12)
        gtk_widget_set_visible(angle, 0)
        let characterCompartment = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        append(characterCompartment, symbolText)
        append(characterCompartment, angle)
        let button = chip(value, drawing: characterCompartment)
        signal(button, "clicked") { [weak self] in
            guard let self else { return }
            let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_size_request(list, 220, -1)
            let panel = self.panelOpen(an: button)
            gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
            for e in entries {
                append(list, self.selectionRow(e.text, selected: e.selected, panel: panel, perform: e.perform))
            }
            gtk_widget_add_css_class(button, "swiftly-aktiv")
            gtk_widget_set_visible(symbolText, 0)
            gtk_widget_set_visible(angle, 1)
            let k = held(button), z = held(symbolText), w = held(angle)
            signal(panel, "closed") {
                gtk_widget_remove_css_class(k.widget, "swiftly-aktiv")
                gtk_widget_set_visible(z.widget, 1)
                gtk_widget_set_visible(w.widget, 0)
                letGo(k); letGo(z); letGo(w)
            }
            gtk_popover_popup(asPanel(panel))
        }
        return button
    }

    /// One row in a picker panel. **Chosen means white, not accent** (`Wahltafelzeile` on macOS).
    private func selectionRow(_ text: String, selected: Bool, panel: Widget!,
                           perform: @escaping () -> Void) -> Widget! {
        let row: Widget! = gtk_button_new()
        gtk_widget_add_css_class(row, "swiftly-handlung")
        gtk_widget_add_css_class(row, "swiftly-wahlzeile")
        if selected { gtk_widget_add_css_class(row, "swiftly-aktiv") }
        help(row, selected: selected)
        let r = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let l = label(text, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        append(r, l)
        if selected {
            let checkmark: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(checkmark), 14)
            append(r, checkmark)
        }
        gtk_button_set_child(asButton(row), r)
        let t = held(panel)
        signal(row, "clicked") {
            if let panel = t.widget { gtk_popover_popdown(asPanel(panel)) }
            perform()
        }
        signal(row, "destroy") { letGo(t) }
        return row
    }

    // MARK: Title menu

    /// **The page title as a menu**: Filme ▾ and Serien ▾, as on macOS (`Titelwahl` in `MacComponents.swift`).
    ///
    /// With two or more entries in the `SectionOffering`, the title becomes a button: "Alle" on top, then "Sammlungen", then after a divider the libraries. This removes the "Bibliotheken" section from the sidebar. The panel opens in place like any picker button, and at most one is open.
    private func titleSelectionInBuild(_ was: Region, title: Widget!) {
        guard let column = gtk_widget_get_parent(title) else { return }
        g_object_ref(UnsafeMutableRawPointer(title))
        gtk_box_remove(asBox(column), title)
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-titelwahl")
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        append(rail, title)
        g_object_unref(UnsafeMutableRawPointer(title))
        // `chevron.down`, 15 semibold; quiet, white when hovered or open.
        let angle: Widget! = gtk_image_new_from_icon_name("pan-down-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(angle), 15)
        gtk_widget_set_valign(angle, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(angle, 0)
        append(rail, angle)
        gtk_button_set_child(asButton(button), rail)
        gtk_widget_set_can_target(button, 0)
        gtk_box_prepend(asBox(column), button)
        signal(button, "clicked") { [weak self] in self?.titleSelectionOpen(was) }
        titleSelection[was] = (button, title, angle)
        signal(button, "destroy") { [weak self] in self?.titleSelection[was] = nil }
    }

    /// Title and chevron follow the offer. **"Alle" is simply called "Filme"**: the title says where the user is; "Alle Filme" appears only in the menu.
    func titleSelectionDraw(_ was: Region) {
        guard let t = titleSelection[was] else { return }
        let an = offering(was)
        let w = sectionSelection(was)
        let text = w == .all ? was.label : selectionLabel(w, was, an)
        gtk_label_set_text(OpaquePointer(t.title), text)
        if let small = barTitle[was] { gtk_label_set_text(OpaquePointer(small), text) }
        gtk_widget_set_visible(t.angle, an.isMenu ? 1 : 0)
        gtk_widget_set_can_target(t.button, an.isMenu ? 1 : 0)
    }

    private func selectionLabel(_ w: SectionSelection, _ was: Region,
                                  _ an: SectionOffering) -> String {
        switch w {
        case .all:
            return was == .seriesList ? translated("Alle Serien") : translated("Alle Filme")
        case .collections:
            return translated("Sammlungen")
        case .playlists:
            return translated("Wiedergabelisten")
        case .library(let id):
            // The name comes from the server and is not translated.
            return an.library(id)?.name ?? ""
        }
    }

    private func titleSelectionOpen(_ was: Region) {
        guard let t = titleSelection[was] else { return }
        let an = offering(was)
        guard an.isMenu else { return }
        let now = sectionSelection(was)
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(list, 260, -1)
        let panel = panelOpen(an: t.button)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
        for entryRecord in an.entries {
            // Before the first library: divider and heading, like `SelectionPanel`.
            if entryRecord == an.firstLibrary {
                let stroke = divider()
                gtk_widget_set_margin_top(stroke, 4)
                gtk_widget_set_margin_bottom(stroke, 4)
                append(list, stroke)
                let over = category(translated("Bibliotheken"))
                gtk_widget_set_margin_start(over, 12)
                gtk_widget_set_margin_top(over, 4)
                gtk_widget_set_margin_bottom(over, 4)
                append(list, over)
            }
            append(list, selectionRow(selectionLabel(entryRecord, was, an),
                                       selected: entryRecord == now, panel: panel) { [weak self] in
                guard let self, entryRecord != self.sectionSelection(was) else { return }
                self.sectionSelect(entryRecord, was)
                self.titleSelectionDraw(was)
                self.chipsFill(was)
                self.gridLoad(was)
            })
        }
        gtk_widget_add_css_class(t.button, "swiftly-aktiv")
        gtk_image_set_from_icon_name(OpaquePointer(t.angle), "pan-up-symbolic")
        let k = held(t.button), w = held(t.angle)
        signal(panel, "closed") {
            gtk_widget_remove_css_class(k.widget, "swiftly-aktiv")
            gtk_image_set_from_icon_name(OpaquePointer(w.widget), "pan-down-symbolic")
            letGo(k); letGo(w)
        }
        gtk_popover_popup(asPanel(panel))
    }

    /// A page heading with the count on the right, "Filme … 7".
    /// - Parameters:
    ///   - mitServer: Whether the server line appears under the title. **Only the library pages** have it; the watchlist (`WatchlistView.swift:42-49`) and the genre page (`GenreView.swift:29`, a plain `SubpageHeader`) do not.
    ///   - mitZahl: Whether the count badge appears on the right. The genre page has none.
    func pageHeader(_ title: String, figure: inout Widget!,
                            titleField: inout Widget!,
                            serverField: inout Widget!,
                            back: (() -> Void)? = nil,
                            withServer: Bool = true,
                            withNumber: Bool = true) -> Widget! {
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        if let back {
            let arrow: Widget! = gtk_button_new()
            gtk_widget_add_css_class(arrow, "swiftly-zurueck")
            caption(arrow, translated("Zurück"))
            gtk_button_set_child(asButton(arrow),
                                 gtk_image_new_from_icon_name("go-previous-symbolic"))
            gtk_widget_set_valign(arrow, GTK_ALIGN_CENTER)
            signal(arrow, "clicked", back)
            append(rail, arrow)
        }
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_hexpand(column, 1)
        let t = label(title, style: "swiftly-titel-gross")
        titleField = t
        gtk_label_set_xalign(OpaquePointer(t), 0)
        append(column, t)

        // **Where am I?** The server name was on no page; with several accounts and identically named libraries it is the only difference. It is shown only if there is one, since an empty second line would be a gap with no meaning.
        let sv = label(serverName, style: "swiftly-zaehlmarke")
        gtk_label_set_xalign(OpaquePointer(sv), 0)
        gtk_label_set_ellipsize(OpaquePointer(sv), PANGO_ELLIPSIZE_END)
        gtk_widget_set_visible(sv, (withServer && !serverName.isEmpty) ? 1 : 0)
        serverField = withServer ? sv : nil
        append(column, sv)
        append(rail, column)

        // **Only from one.** macOS shows the count only for `total > 0` (`LibraryView.swift:80`, `WatchlistView.swift:48`); here an empty result showed a "0" next to the heading.
        figure = label("", style: "swiftly-zaehlmarke")
        gtk_widget_set_valign(figure, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(figure, 0)
        if withNumber { append(rail, figure) }
        return rail
    }

    /// **The home page gets no side inset.**
    ///
    /// The page inset would cut off the horizontal scroll area.
    ///
    /// On macOS the row carries the inset **inside** (`Blätterreihe.rand`): the tiles start under the heading and still scroll to the window edge. Same here.
    private func startSectionBuild() -> Widget! {
        // **The home page has a title** (like macOS): movies, series, search, watchlist and downloads all have a heading, only the home page lacked one. Same size, same place, same `Bestandsleiste` when scrolling.
        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: Int32(Theme.railsSpacing))
        // **The same scroller as everywhere**: `EXTERNAL`, no system scrollbar.
        let scroller = pagesScroller()
        // The top spacing lives in the stylesheet as `padding` (`contentTop`).
        gtk_widget_add_css_class(page, "swiftly-startschein")
        lookGlowOn(page)
        // **Full width.** Without it the stack keeps the width it had when sliding in after a back.
        gtk_widget_set_hexpand(page, 1)
        gtk_widget_set_halign(page, GTK_ALIGN_FILL)
        gtk_widget_set_margin_bottom(page, 40)

        let title = label(translated("Startseite"), style: "swiftly-titel-gross")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_widget_set_hexpand(title, 1)
        // The heart sits at the right end of the title row ("Support Swiftly").
        let titleRow = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_start(titleRow, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(titleRow, Int32(Theme.edgeSpacing))
        append(titleRow, title)
        append(titleRow, supportHeart())
        append(page, titleRow)

        // **The page has no side inset**; the row carries it inside (`Blätterreihe.rand`) so the tiles scroll to the window edge.
        railsStack = stack(GTK_ORIENTATION_VERTICAL, spacing: Int32(Theme.railsSpacing))
        gtk_widget_set_hexpand(railsStack, 1)
        append(page, railsStack)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), page)
        return stateBar(scroller, title: translated("Startseite")).wrapper
    }

    private func gridPageBuild(_ was: Region) -> Widget! {
        // **Spacing of the original** (`LibraryView`): title, 14 gap, the value row, 22 gap, the grid.
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        var figure: Widget!
        var title: Widget!
        var serverRow: Widget!
        // **A genre page is not a root** and therefore carries a back arrow in the content, like any subpage (`Sources/macOS/GenreView.swift:29`, `SubpageHeader`). Movies, series, watchlist and library are in the bar and carry the `Bestandsleiste`.
        append(block, pageHeader(was.label, figure: &figure, titleField: &title,
                                    serverField: &serverRow,
                                    back: was == .genre ? { [weak self] in
                                        self?.show(.start)
                                    } : nil,
                                    withServer: was != .genre && was != .watchlist
                                        && was != .collection,
                                    withNumber: was != .genre))
        // Only these pages change their title.
        if was == .collection { collectionTitle = title }
        if was == .movies || was == .seriesList { titleSelectionInBuild(was, title: title) }
        if was == .genre { genreTitle = title }
        // `nil` where the page has none; otherwise `serverRowsDraw` would colour it anyway.
        serverRows[was] = serverRow

        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_top(row, 14)
        chipRows[was] = row
        append(block, row)
        chipsFill(was)

        // **No "Lade …" as body text**: a placeholder in the shape of what is coming.
        let loader = gridPlaceholder(count: 6, margin: 0)
        gtk_widget_set_halign(loader, GTK_ALIGN_START)
        gtk_widget_set_margin_top(loader, 22)
        gtk_widget_set_visible(loader, 0)
        append(block, loader)

        let grid = gridBuild()
        gtk_widget_set_margin_top(grid, was == .genre ? 20 : 22)
        append(block, grid)

        // **Empty or failed, never nothing.** Movies, series and the library had no state at all here: if the page loaded nothing, nothing was shown. `gridStateShow(_:disrupted:)` decides after the response what appears.
        let condition = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_visible(condition, 0)
        append(block, condition)
        emptyField[was] = condition
        gridField[was] = grid
        // A new grid is empty; otherwise `gridLoad` would think something was already there.
        gridItems[was] = []
        numberField[was] = figure
        loaderField[was] = loader

        let frameRect = pagesFrame(block)
        // Tiles scrolled far away release their images (`TileImageGuard`).
        let sentry = TileImageGuard(scroller: frameRect)
        let gridPointer = UnsafeMutableRawPointer(grid!)
        tileGuard[gridPointer] = sentry
        signal(grid, "destroy") { [weak self] in self?.tileGuard[gridPointer] = nil }
        // **More is loaded at the bottom edge** (`edge-reached`; the signal carries the edge, so again a dedicated callback).
        // **A genre page loads once.** macOS fetches exactly 200 there and does not page (`GenreView.swift:69-72`).
        if was != .genre {
            edgeReport(frameRect) { [weak self] in self?.gridLoadMore(was) }
        }
        // The genre page carries the `SubpageHeader` with the arrow in the content, as on macOS; no `Bestandsleiste`.
        if was == .genre { return withHeaderLine(frameRect) }
        // **The collection is a subpage:** the arrow is in the bar, as on macOS (`Bestandsleiste.back`), and does not fade in.
        let bar = stateBar(frameRect, title: was.label,
                                    back: was == .collection ? { [weak self] in
                                        self?.collectionClose()
                                    } : nil,
                                    valueSeries: row)
        barTitle[was] = bar.title
        if was == .movies || was == .seriesList || was == .collection {
            alphabetStripBuild(was, over: bar.wrapper, scroller: frameRect)
        }
        return bar.wrapper
    }

    /// **Empty or failed**, after the response, taken literally from `LibraryView`, `WatchlistView` and `GenreView` on macOS.
    func gridStateShow(_ was: Region, disrupted: Bool, empty: Bool) {
        guard let inputField = emptyField[was] else { return }
        wipe(inputField)
        guard empty else { gtk_widget_set_visible(inputField, 0); return }
        let newLoad: () -> Void = { [weak self] in self?.gridLoad(was) }
        if disrupted {
            append(inputField, disturbState(top: 80, retry: newLoad))
        } else {
            switch was {
            case .watchlist:
                let memo = RememberCharacter(filled: false, mass: 44)
                signal(memo.display, "destroy") { _ = memo }
                append(inputField, emptyState("", translated("Noch nichts gemerkt"),
                                            translated("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier."),
                                            top: 80, drawing: memo.display))
            case .genre:
                append(inputField, emptyState("tag-symbolic", translated("Nichts in diesem Genre"),
                                            translated("In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien."),
                                            top: 80))
            default:
                let filter = filterFrom(was)
                if filter == .all {
                    append(inputField, emptyState("mail-inbox-symbolic", translated("Hier ist noch nichts"),
                                                was == .collection
                                                    ? translated("Sobald in dieser Sammlung etwas liegt, taucht es hier auf.")
                                                    : translated("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."),
                                                top: 80,
                                                quietButton: (translated("Aktualisieren"), newLoad)))
                } else {
                    let symbolText = FilterCharacter(mass: 44)
                    append(inputField, emptyState("", translated("Nichts gefunden"),
                                                String(format: translated("Unter „%@“ liegt gerade nichts. Nimm einen anderen Filter."),
                                                       filter.label),
                                                top: 80,
                                                quietButton: (translated("Filter zurücksetzen"), { [weak self] in
                                                    guard let self else { return }
                                                    self.filterSet(was, .all)
                                                    self.chipsFill(was)
                                                    self.gridLoad(was)
                                                }),
                                                drawing: symbolText.display))
                    signal(symbolText.display, "destroy") { _ = symbolText }
                }
            }
        }
        gtk_widget_set_visible(inputField, 1)
    }

    /// **Filter on the left, sort on the right**, as on macOS.
    ///
    /// Both lists come from `JellyfinKit.LibraryFilter` and `Sorting`. That is also where their server meaning is documented, and why "Ungesehen" deliberately has its own switch instead of Jellyfin's `Filters=IsUnplayed`, which works per episode for series.
    /// The libraries of one kind.
    func libraries(for was: Region) -> [Item] {
        // **The watchlist has none.** It spans all libraries and filters on `IsFavorite` at the server; a library choice would be a restriction that macOS does not have either.
        switch was {
        case .movies:  return review.filter { $0.collectionType == "movies" }
        case .seriesList: return review.filter { $0.collectionType == "tvshows" }
        default:      return []
        }
    }

    func chipsFill(_ was: Region) {
        guard let row = chipRows[was] else { return }
        wipe(row)
        // **A genre page has no chips.** macOS shows neither filter nor sort there (`Sources/macOS/GenreView.swift`): the order is fixed to "recently added", since one taps a genre to see what is new. Both rows used to hang here: the sort chip lit up and did nothing because `gridLoad` forces `DateCreated` for genres anyway, and the filter chip did something the original does not.
        if was == .genre {
            gtk_widget_set_visible(row, 0)
            return
        }
        gtk_widget_set_visible(row, 1)
        let nowFilter = filterFrom(was)
        let nowSort = sortingFrom(was)

        // **The library choice is not here.** It used to be chips up front; now it is the title menu above, which also takes the heading along (macOS `LibraryView`).

        // **The watchlist chooses the kind, not the state.** The server already filters on `IsFavorite`, so a state filter would do nothing there. Instead the kind pill, which was missing on Linux entirely, leaving no way to separate movies and series.
        // **Two picker buttons instead of a chip row.**
        let sortUp = Sorting.allCases.map { fall in
            (text: fall.label, selected: fall == nowSort, perform: { [weak self] () -> Void in
                guard let self, fall != self.sortingFrom(was) else { return }
                self.sortingSet(was, fall)
                self.chipsFill(was)
                self.gridLoad(was)
            })
        }
        if was == .watchlist {
            let grid: Widget! = gtk_image_new_from_icon_name("view-grid-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(grid), 12)
            append(row, selectionButton(symbolText: grid, value: savedGenre.label,
                                       entries: RememberGenre.allCases.map { fall in
                (text: fall.label, selected: fall == savedGenre, perform: { [weak self] () -> Void in
                    guard let self, fall != self.savedGenre else { return }
                    self.savedGenre = fall
                    self.chipsFill(was)
                    self.gridLoad(was)
                })
            }))
        } else {
            let funnel = FilterCharacter()
            signal(funnel.display, "destroy") { _ = funnel }
            append(row, selectionButton(symbolText: funnel.display, value: nowFilter.label,
                                       entries: filterList(was).map { fall in
                (text: fall.label, selected: fall == nowFilter, perform: { [weak self] () -> Void in
                    guard let self, fall != self.filterFrom(was) else { return }
                    self.filterSet(was, fall)
                    self.chipsFill(was)
                    self.gridLoad(was)
                })
            }))
        }
        // The icon of the chosen sort order, not the same arrows for all (macOS `Sorting.symbol`).
        let arrows: Widget! = characterImage(nowSort.characterNames)
        gtk_image_set_pixel_size(OpaquePointer(arrows), 12)
        append(row, selectionButton(symbolText: arrows, value: nowSort.label,
                                   entries: sortUp))
        // **For "Sammlungen" the row stays, just empty** (macOS `LibraryView`): the list of collections needs neither filtering nor sorting. If the row disappeared, the grid would jump by its height on switching.
        let empty = (was == .movies || was == .seriesList)
            && (sectionSelection(was) == .collections || sectionSelection(was) == .playlists)
        var kind = gtk_widget_get_first_child(row)
        while let k = kind {
            gtk_widget_set_opacity(k, empty ? 0 : 1)
            gtk_widget_set_can_target(k, empty ? 0 : 1)
            kind = gtk_widget_get_next_sibling(k)
        }
    }

    /// Which filters are offered; for the series of a collection the same set as macOS (`CollectionDetailPage`).
    /// Without the watchlist when it is switched off.
    private func filterList(_ was: Region) -> [LibraryFilter] {
        let all: [LibraryFilter] = was == .collection && openCollection?.art == "tvshows"
            ? [.all, .begun, .watchlist] : LibraryFilter.allCases
        return LibraryFilter.offered(all, watchlist: selection.watchlistShown)
    }

    // MARK: Collections in the grid (macOS `LibraryView.collectionTiles`)

    /// **Collections in the same grid, with the same tile.** Under the name, instead of the year, is how many movies or series it holds. Without its own image, a mosaic of the first posters is shown.
    private func collectionsShow(_ was: Region) {
        gridJob[was, default: 0] += 1
        gridLoads.remove(was)
        gridLoaderShow(was, false)
        gridFilter[was] = nil
        gridRaw[was] = nil
        gridItems[was] = []
        guard let grid = gridField[was], let figure = numberField[was] else { return }
        gridFill(grid, [])
        let genre = art(was)
        let count: Int
        if sectionSelection(was) == .playlists {
            // Playlists in the same grid with the same tile (macOS `LibraryView.playlistTiles`).
            let lists = playlistDirectory?.playlists(art: genre) ?? []
            for list in lists {
                gtk_flow_box_insert(OpaquePointer(grid), playlistTile(list, art: genre), -1)
            }
            count = lists.count
        } else {
            let list = collectionDirectory?.collections(art: genre) ?? []
            for entryRecord in list {
                gtk_flow_box_insert(OpaquePointer(grid), collectionTile(entryRecord, art: genre), -1)
            }
            count = list.count
        }
        gtk_label_set_text(OpaquePointer(figure), String(count))
        gtk_widget_set_visible(figure, count == 0 ? 0 : 1)
        // "Sammlungen" appears in the menu only if there are any; no loading, no empty state.
        gridStateShow(was, disrupted: false, empty: false)
    }

    private func collectionTile(_ collection: ItemCollection, art genre: String) -> Widget! {
        let item = collection.item
        let (cage, image) = framedImage(width: Theme.tileWidth,
                                           height: Theme.tileHeight,
                                           style: "swiftly-plakat")
        if item.imageTags?["Primary"] != nil,
           let address = addresses.flatMap({ ImageSelection.portrait(item, addresses: $0,
                                                              maxHeight: Scaling.requestEdge(Theme.tileHeight)) }) {
            imageLoad(image, url: address, key: ImageKey.of(address),
                      border: Scaling.imageEdge(Theme.tileHeight))
        } else {
            mosaicPut(cage, collection: collection, art: genre)
        }
        let n = collection.count(art: genre)
        let bottom = genre == "tvshows"
            ? numberWord(n, one: translated("1 Serie"), many: translated("%lld Serien"))
            : numberWord(n, one: translated("1 Film"), many: translated("%lld Filme"))
        let tile = tileWrapper(image: cage, width: Theme.tileWidth,
                                  top: item.name, bottom: bottom) { [weak self] in
            self?.collectionOpen(item, art: genre)
        }
        gtk_widget_set_halign(tile, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(tile, GTK_ALIGN_START)
        return tile
    }

    /// **Fallback poster of a collection without its own image**: a mosaic of the posters of its first titles (macOS `Sammlungsmosaik`). One title fills the field, two sit side by side, from three a 2×2 mosaic, with a 2-point gap. The posters are fetched small (260 points high). Until they arrive, the icon is shown on the surface.
    private func mosaicPut(_ cage: Widget!, collection: ItemCollection, art genre: String) {
        characterPut(cage, series: genre == "tvshows")
        guard let client else { return }
        let source = ShelfSource(parent: collection.id, art: genre, collection: true)
        let container = held(cage)
        Task.detached { [self] in
            let title = (try? await client.items(parentID: source.parent, limit: 4,
                                                 sortBy: Sorting.erscheinung.inputField,
                                                 sortOrder: source.bearing(.erscheinung),
                                                 recursive: source.recursive,
                                                 includeItemTypes: source.types).items) ?? []
            onMainThread {
                defer { letGo(container) }
                guard let cage = container.widget, !title.isEmpty else { return }
                let rails: [[Item]] = title.count > 2
                    ? [Array(title.prefix(2)), Array(title[2...].prefix(2))] : [title]
                let width = Theme.tileWidth, height = Theme.tileHeight
                let railsHeight = (height - (rails.count - 1) * 2) / rails.count
                let mosaic = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
                gtk_widget_add_css_class(mosaic, "swiftly-mosaik")
                gtk_widget_set_can_target(mosaic, 0)
                for rail in rails {
                    let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
                    let fieldWidth = (width - (rail.count - 1) * 2) / rail.count
                    for entryRecord in rail {
                        let (inputField, image) = framedImage(width: fieldWidth, height: railsHeight,
                                                         style: "swiftly-mosaikfeld")
                        if let address = self.addresses.flatMap({
                            ImageSelection.portrait(entryRecord, addresses: $0, maxHeight: 260) }) {
                            imageLoad(image, url: address, key: ImageKey.of(address),
                                      border: 260)
                        } else {
                            characterPut(inputField, series: genre == "tvshows")
                        }
                        append(row, inputField)
                    }
                    append(mosaic, row)
                }
                gtk_overlay_add_overlay(OpaquePointer(cage), mosaic)
            }
        }
    }

    private func searchBuild() -> Widget! {
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 20)
        var unused: Widget!
        var unusedTitle: Widget!
        var unusedServerRow: Widget!
        append(block, pageHeader(translated("Suche"), figure: &unused,
                                    titleField: &unusedTitle,
                                    serverField: &unusedServerRow))

        // **"Titel, Serie, Person", not "Suchen".** The placeholder says **what** can be searched for (`SearchView.swift:100`); "Suchen" would only repeat the heading above.
        searchField = inputRow(symbol: "system-search-symbolic",
                                placeholder: translated("Titel, Serie, Person"))
        // **420 wide, not across the page**: `SearchView.swift:102` caps it with `frame(maxWidth: 420)`. A field 1200 points wide looks like it expects a sentence.
        gtk_widget_set_size_request(searchField, 420, Int32(Theme.fieldHeight))
        gtk_widget_set_halign(searchField, GTK_ALIGN_START)
        gtk_widget_set_hexpand(searchField, 0)
        append(block, searchField)

        // **"Zuletzt gesucht", the same list as on iPhone, TV and macOS.** The logic is `SearchHistory` in the package and had never been connected here: with an empty field Linux showed nothing.
        let (historyOuter, historySpace) = rowsGroup()
        searchHistoryBlock = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let historyHeader = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_top(historyHeader, 26)
        gtk_widget_set_margin_bottom(historyHeader, 8)
        let historyTitle = category(translated("Zuletzt gesucht"))
        gtk_widget_set_hexpand(historyTitle, 1)
        append(historyHeader, historyTitle)
        let historyDistance: Widget! = gtk_button_new()
        gtk_widget_add_css_class(historyDistance, "swiftly-blank")
        gtk_button_set_child(asButton(historyDistance),
                             label(translated("Löschen"), style: "swiftly-zaehlmarke"))
        signal(historyDistance, "clicked") { [weak self] in
            self?.searchHistorySet("")
            self?.selection.secure()
            self?.searchHistoryShow()
        }
        append(historyHeader, historyDistance)
        append(searchHistoryBlock, historyHeader)
        append(searchHistoryBlock, historyOuter)
        searchHistoryList = historySpace
        // 700 wide and left-aligned (`SearchView.swift:83`, `frame(maxWidth: Theme.readWidth, alignment: .leading)`). Without the cap the card ran across the whole window, and a word list 1200 points wide is hard to read.
        gtk_widget_set_size_request(searchHistoryBlock, Int32(Theme.readWidth), -1)
        gtk_widget_set_halign(searchHistoryBlock, GTK_ALIGN_START)
        append(block, searchHistoryBlock)

        // **While nothing else is shown, the page says what can be searched for.** On macOS this replaces the history list when there is no history (`SearchView.swift:109`); on Linux the page stayed empty under the field.
        searchHint = emptyState("system-search-symbolic",
                                  translated("Filme, Serien und Folgen durchsuchen"), nil)
        gtk_widget_set_visible(searchHint, 0)
        append(block, searchHint)

        searchGrid = gridBuild()
        append(block, searchGrid)
        // **Empty is information.** Without it the page just sits there, and the user cannot tell whether a search ran or nothing exists.
        searchEmpty = emptyState("mail-inbox-symbolic", translated("Nichts gefunden"), nil)
        gtk_widget_set_visible(searchEmpty, 0)
        append(block, searchEmpty)
        // **Failed is not empty** (macOS `SearchView` `disrupted`). This used `try?`, so a network error looked like "Nichts gefunden". It is filled only on error, so the address is that of the currently logged-in server.
        searchDisturbance = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_visible(searchDisturbance, 0)
        append(block, searchDisturbance)

        // **What the server does not have is shown below, not mixed in.**
        //
        // Same layout as the Apple version: the own library first, then a separate heading and below it what Seerr knows. Mixed together, it would not be visible what can be watched and what must first be requested.
        // **Both search blocks carry the count badge on the right.** Only the heading used to be there; how many hits Seerr has was not shown.
        let seerrRow = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_top(seerrRow, 12)
        gtk_widget_set_visible(seerrRow, 0)
        // **A section heading, not a row heading.** On macOS this is 13 semibold uppercase with 0.5 tracking in `schriftSehrLeise` (`SearchView.swift:143`); here it was `swiftly-reihe`, 20 points like above a home row. That made the Seerr block heavier than the own results above, which have no heading.
        seerrHeading = category(translated("Kann angefragt werden"))
        gtk_label_set_xalign(OpaquePointer(seerrHeading), 0)
        gtk_widget_set_hexpand(seerrHeading, 1)
        append(seerrRow, seerrHeading)
        seerrNumber = label("", style: "swiftly-zaehlmarke")
        gtk_widget_set_valign(seerrNumber, GTK_ALIGN_CENTER)
        append(seerrRow, seerrNumber)
        seerrHeaderRow = seerrRow
        append(block, seerrRow)

        seerrGrid = gridBuild()
        gtk_widget_set_visible(seerrGrid, 0)
        append(block, seerrGrid)
        // The Enter key searches immediately and becomes the latest search itself; otherwise the timer of the still-running wait would discard it.
        signal(searchField, "activate") { [weak self] in
            guard let self else { return }
            self.searchTick += 1
            // **Remembered only here.** See `searching(_:merken:)`.
            self.searching(self.searchTick, remember: true)
        }
        signal(searchField, "changed") { [weak self] in self?.searchTriggered() }
        return pagesFrame(block)
    }

    /// **A scroll area without a bar, but with smooth scrolling.**
    ///
    /// Nobody needs the vertical bar; scrolling is done with the wheel, and a bar over the content is the same nuisance as the horizontal one in the rows. `EXTERNAL` means: scroll yes, bar no.
    ///
    /// `softScroll` provides the smooth motion; otherwise GTK jumps from detent to detent on the wheel.
    func pagesScroller() -> Widget! {
        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        softScroll(scroller)
        return scroller
    }

    /// Shows or hides the loading indicator over a grid.
    ///
    /// When filter, sort or library changed, the old grid stayed until the new one arrived, so it looked as if the click had done nothing.
    func gridLoaderShow(_ was: Region, _ an: Bool) {
        guard let loader = loaderField[was] else { return }
        gtk_widget_set_visible(loader, an ? 1 : 0)
    }

    /// **Empty is information, not an empty box**: the anatomy of `Leerzustand` on macOS: circle 78 on `area`, icon 44 in `schriftLeise`, 22 gap, heading 20 semibold, 7 gap, text 15 in `schriftLeise` at most 262 wide, and two optional buttons: the main button "Erneut versuchen" and a quiet one in the accent colour.
    ///
    /// **A button only if there is something to do.** For "Nichts gemerkt" or "Nichts gefunden" the way out is the list or the back button, not a dummy.
    func emptyState(_ symbol: String, _ title: String, _ text: String?,
                     top: Int = 100,
                     primaryButton main: (String, () -> Void)? = nil,
                     quietButton still: (String, () -> Void)? = nil,
                     drawing: Widget? = nil) -> Widget! {
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(block, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(block, Int32(top))
        gtk_widget_set_margin_start(block, 34)
        gtk_widget_set_margin_end(block, 34)

        let circle = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(circle, "swiftly-leerkreis")
        gtk_widget_set_size_request(circle, 78, 78)
        gtk_widget_set_halign(circle, GTK_ALIGN_CENTER)
        // A drawn icon where the icon font has nothing suitable.
        let image: Widget! = drawing ?? gtk_image_new_from_icon_name(symbol)
        if drawing == nil { gtk_image_set_pixel_size(OpaquePointer(image), 44) }
        gtk_widget_set_halign(image, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(image, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(image, 1)
        append(circle, image)
        // **The circle does not stretch.** `vexpand` on the icon centres it in the circle, but without this line it propagated up to the circle, which then took any free height of the page and became a long capsule (measured headless: 78 × 460 instead of 78 × 78). The propagation ends here.
        gtk_widget_set_vexpand(circle, 0)
        gtk_widget_set_hexpand(circle, 0)
        gtk_widget_set_valign(circle, GTK_ALIGN_START)
        append(block, circle)

        let t = label(title, style: "swiftly-reihe", wrap: true)
        gtk_widget_set_halign(t, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(t, 22)
        append(block, t)
        // **No empty line without a subline.** An empty field below would be a hole.
        if let text {
            let u = label(text, style: "swiftly-koerper", wrap: true)
            gtk_widget_add_css_class(u, "dim-label")
            gtk_label_set_justify(OpaquePointer(u), GTK_JUSTIFY_CENTER)
            gtk_label_set_max_width_chars(OpaquePointer(u), 1)
            gtk_widget_set_size_request(u, 262, -1)
            gtk_widget_set_halign(u, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_top(u, 7)
            append(block, u)
        }
        if let (word, perform) = main {
            let k = primaryButton(word, symbol: "view-refresh-symbolic")
            gtk_widget_set_size_request(k, -1, Int32(Theme.primaryButtonHeight))
            gtk_widget_set_margin_top(k, 24)
            signal(k, "clicked", perform)
            append(block, k)
        }
        if let (word, perform) = still {
            let k = quietButton(word, perform)
            gtk_widget_set_margin_top(k, main == nil ? 24 : 16)
            append(block, k)
        }
        return block
    }

    /// The quiet button: 15 medium in the accent colour, 44 high, no surface; the second action of an empty or failed state.
    func quietButton(_ word: String, _ perform: @escaping () -> Void) -> Widget! {
        let k: Widget! = gtk_button_new_with_label(word)
        gtk_widget_add_css_class(k, "swiftly-still")
        gtk_widget_set_halign(k, GTK_ALIGN_CENTER)
        signal(k, "clicked", perform)
        return k
    }

    /// **The server address in the error text**, like `model.serverAddress` on Apple; without a session "Der Server".
    var serverAddressText: String {
        client?.baseURL.host ?? translated("Der Server")
    }

    /// **Failed is not empty.** A whole page whose request failed: the same server wording as everywhere, taken literally from `HomeView.swift`.
    func disturbState(top: Int = 120, retry: @escaping () -> Void) -> Widget! {
        emptyState("network-offline-symbolic", translated("Server ist abgetaucht"),
                    String(format: translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?"),
                           serverAddressText),
                    top: top,
                    primaryButton: (translated("Erneut versuchen"), retry))
    }

    /// **A failed section within a page**: `DisturbHint` on macOS: icon 30, heading 20, text 15 in `schriftSehrLeise`, below it "Erneut versuchen" as a chip.
    func disturbHint(top: Int = 40, address: String? = nil,
                      retry: (() -> Void)?) -> Widget! {
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(block, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(block, 1)
        gtk_widget_set_margin_top(block, Int32(top))
        let image: Widget! = gtk_image_new_from_icon_name("network-offline-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(image), 30)
        gtk_widget_add_css_class(image, "dim-label")
        append(block, image)
        let t = label(translated("Server ist abgetaucht"), style: "swiftly-reihe")
        gtk_widget_set_margin_top(t, 14)
        append(block, t)
        let u = label(String(format: translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?"),
                                    address ?? serverAddressText),
                             style: "swiftly-koerper", wrap: true)
        gtk_widget_add_css_class(u, "swiftly-leise")
        gtk_label_set_max_width_chars(OpaquePointer(u), 1)
        gtk_widget_set_size_request(u, 262, -1)
        gtk_widget_set_halign(u, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(u, 6)
        append(block, u)
        if let retry {
            // **A button from the shared set, not bare text.** The quiet button had no surface and no side border here and did not look like a button; the chip is the standard button for a secondary action.
            let k = chip(translated("Erneut versuchen"), symbol: "view-refresh-symbolic")
            gtk_widget_set_halign(k, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_top(k, 14)
            signal(k, "clicked", retry)
            append(block, k)
        }
        return block
    }

    /// An empty section *within* a page, `EmptyHint`: one line 15 in `schriftSehrLeise`, centred, 40 above.
    func emptyHint(_ text: String) -> Widget! {
        let l = label(text, style: "swiftly-koerper")
        gtk_widget_add_css_class(l, "swiftly-leise")
        gtk_widget_set_halign(l, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(l, 1)
        gtk_widget_set_margin_top(l, 40)
        return l
    }

    /// A wrapping grid. GTK's `GtkFlowBox` does exactly what a `LazyVGrid` with fixed column width does on macOS.
    func gridBuild() -> Widget! {
        let grid: Widget! = gtk_flow_box_new()
        gtk_flow_box_set_selection_mode(OpaquePointer(grid), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(OpaquePointer(grid), 1)
        gtk_flow_box_set_column_spacing(OpaquePointer(grid), UInt32(Theme.tileSpacing))
        gtk_flow_box_set_row_spacing(OpaquePointer(grid), UInt32(Theme.railsSpacing))
        gtk_flow_box_set_min_children_per_line(OpaquePointer(grid), 2)
        gtk_flow_box_set_max_children_per_line(OpaquePointer(grid), 10)
        gtk_widget_set_valign(grid, GTK_ALIGN_START)
        return grid
    }

    /// - Parameter auskunft: Whether the second line carries the full result info ("Serie · 3 Staffeln", "Breaking Bad · S1 E4 · 52 Min.") instead of just the year. **Search only.** macOS sets it there (`SearchView.swift:117`) and not in the library (`LibraryView.swift:136`).
    func gridFill(_ grid: Widget!, _ items: [Item], inquiry: Bool = false) {
        gridEmpty(grid)
        gridAppend(grid, items, inquiry: inquiry)
    }

    /// Appends tiles to a grid without touching the existing ones.
    func gridAppend(_ grid: Widget!, _ items: [Item], inquiry: Bool = false) {
        let sentry = grid.flatMap { tileGuard[UnsafeMutableRawPointer($0)] }
        for item in items {
            gtk_flow_box_insert(OpaquePointer(grid),
                                gridTile(item, inquiry: inquiry, sentry: sentry), -1)
        }
    }

    /// How many tiles are in the grid. The FlowBox does not count itself, so the first empty slot is searched by bisection.
    func gridCount(_ grid: Widget!) -> Int {
        let box = OpaquePointer(grid)
        var top = 1
        while gtk_flow_box_get_child_at_index(box, Int32(top - 1)) != nil { top *= 2 }
        var bottom = top / 2   // something is surely there (or it is 0)
        while bottom < top {
            let center = (bottom + top + 1) / 2
            if gtk_flow_box_get_child_at_index(box, Int32(center - 1)) != nil { bottom = center }
            else { top = center - 1 }
        }
        return bottom
    }

    /// **A grid is emptied through the FlowBox, never with `leeren(_:)`.**
    ///
    /// `leeren` detaches children with `gtk_widget_unparent`, but the FlowBox keeps its own list of children and does not learn of it. The Seerr results were emptied that way: from the second search on, new tiles hung behind entries that no longer existed, and the grid stayed empty while the badge next to it said "3".
    func gridEmpty(_ grid: Widget!) {
        // **The same construction that once hung the app.** The loop depended on a child existing rather than on progress: if `gtk_flow_box_remove` fails (the pointer is cast blindly for it), `get_child_at_index` returns the same child again and it goes on forever. In `leeren(_:)` that caused a full core and a log of 58 MB per second.
        while let kind = gtk_flow_box_get_child_at_index(OpaquePointer(grid), 0) {
            gtk_flow_box_remove(OpaquePointer(grid),
                                unsafeBitCast(kind, to: Widget.self))
            guard gtk_flow_box_get_child_at_index(OpaquePointer(grid), 0) != kind
            else { break }
        }
    }

    // MARK: Loading

    /// **Without this the session shows up in the dashboard but cannot be controlled.** Two things are missing: the capabilities message, without which the server shows no buttons at all, and the socket over which the commands arrive. Both live in the package and Linux never used them, so the client could be neither remote-controlled nor taken over.
    func remoteControlStart() {
        guard let client else { return }
        let session = sharedSession
        Task.detached {
            try? await client.reportCapabilities()
            guard let far = try? await client.remoteControl() else { return }
            onMainThread { self.remoteControl = far }
            // **Watching together arrives over the same channel.** Straight into the session, not via the GTK thread: `accept` is built for that, and the session itself keeps the order of messages.
            await far.syncPlayHear { session.accept($0) }
            // **The notice before a stop**: another device is taking over. With it, the picture leaves as a card on stop (`handoffHandIn(an:)`); without it the player closes as for a stop from the dashboard (Apple `AppModel.remoteStart`).
            await far.handoffHear { name in
                onMainThread {
                    self.handoffTarget = (name, Date())
                    AppLog.writeOut("[Uebergabe] Hinweis: übernimmt \(name)")
                }
            }
            // **A title sent from another device** opens like a click on "play" here.
            await far.playHear { order in
                onMainThread { self.playReceived(order) }
            }
            await far.start { command in
                onMainThread { self.remoteCommandRun(command) }
            }
        }
    }

    /// **A title another device sent here** (dashboard, web client): the same path as a click
    /// on "play", with position, version and tracks from the order, loaded with this user.
    ///
    /// - **Not while watching together**: the group owns the player and the title, so the
    ///   order is ignored and logged.
    /// - **A running film is replaced, but only once the new title has loaded**: if it cannot
    ///   be loaded, the film keeps playing. The old one closes through its own stop, so its end
    ///   is reported like any other, and the latest order wins.
    func playReceived(_ order: PlayOrder) {
        guard let client, let id = order.itemID else { return }
        guard gemeinsam.status.group == nil else {
            AppLog.writeOut("[Abspielen auf] Auftrag ignoriert: Gruppe aktiv (\(id))")
            return
        }
        playReceivedCount += 1
        let mine = playReceivedCount
        Task.detached { [self] in
            guard let item = try? await client.item(id: id) else {
                AppLog.writeOut("[Abspielen auf] Titel nicht ladbar: \(id)")
                return
            }
            onMainThread {
                guard mine == self.playReceivedCount, self.gemeinsam.status.group == nil else { return }
                if self.runningTitle != nil {
                    AppLog.writeOut("[Abspielen auf] laufender Player wird ersetzt")
                    self.playerClose()
                }
                self.playOrderedTracks = (id, order.tracks)
                self.launch(item, since: order.start, sourceID: order.mediaSourceID)
            }
        }
    }

    /// What the media key triggers. The same actions as the button.
    func mediaHandle(_ grip: MediaBar.Handle) {
        switch grip {
        case .prefetch:
            gtk_window_present(asWindow(window)); return
        case .close:
            // Via `close-request`, so a running film still sends its final report (`windowCloseRequested()`).
            gtk_window_close(asWindow(window)); return
        case .sleeps:
            idleStateStart(); return
        case .woke:
            woke(); return
        default: break
        }
        guard runningTitle != nil else { return }
        // **In a group, a request**, like the playback centre on iOS (`PlayerScreen.zentraleEinrichten`); no next episode.
        if inGroup {
            switch grip {
            case .play:  sharedBitToggle(runningCurrently: false)
            case .halt:   sharedBitToggle(runningCurrently: true)
            case .toggle: sharedBitToggle(runningCurrently: playState.running)
            case .finish:    playerClose()
            default:          break
            }
            return
        }
        // Window and idle inhibition are already handled above.
        switch grip {
        case .play:  resumePlaying()
        case .halt:   mediaPlayer.halt()
        case .toggle: if mediaPlayer.running { mediaPlayer.halt() } else { resumePlaying() }
        case .finish:    playerClose(); return
        case .proceed:     nextEpisode(); return
        default:          break
        }
        playState.running = mediaPlayer.running
        playerPlayMarker?.setDown(playState.running)
        mediaStateReport()
        controlsShow()
    }

    /// Tells the environment what is playing. **After every change**: D-Bus does not ask on its own, and a player that reports nothing stays on "Paused" forever.
    func mediaStateReport() {
        guard let title = runningTitle else {
            mediaBar?.reportStatus(running: false, title: "", subtitle: "",
                                      duration: 0, spot: 0)
            return
        }
        // **With poster.** macOS puts it into the playback centre as `MPMediaItemPropertyArtwork` (`Sources/Shared/PlaybackHub.swift:210`); MPRIS has `mpris:artUrl` for it, and the tile in the system bar had no image. **The address, not the bytes**: each environment fetches the image itself, and the address carries no access token (`ImageKey`).
        let poster = addresses.flatMap {
            ImageSelection.portrait(title, addresses: $0, maxHeight: 600)
        }
        mediaBar?.reportStatus(running: playState.running,
                                  title: title.name,
                                  subtitle: title.contextLine ?? title.seriesName ?? "",
                                  duration: playState.duration,
                                  spot: playState.position,
                                  image: poster?.absoluteString ?? "")
        // "Next" is active only if there is a next episode: the prefetched one, not merely "is an episode".
        mediaBar?.nextReport(prefetchedEpisode != nil)
    }

    /// What another device triggers here. The same actions as the button.
    func remoteCommandRun(_ command: RemoteCommand) {
        guard runningTitle != nil else {
            // Without a running title there is nothing to control; "stopp" would otherwise close nothing.
            return
        }
        // **In a group, pause, next and seek go out as a request**, literally `PlayerScreen.ausfuehren` on iOS. Stop closes, which means leaving.
        if inGroup {
            let running = playState.running
            switch command {
            case .pause:      if running { sharedBitToggle(runningCurrently: true) }
            case .proceed:     if !running { sharedBitToggle(runningCurrently: false) }
            case .toggle: sharedBitToggle(runningCurrently: running)
            case .stop:      playerClose(); return
            case let .jumpOn(spot): vault(on: spot)
            case .forward:        vault(um: Double(selection.forwardSeconds))
            case .back:    vault(um: -Double(selection.backSeconds))
            case .next, .previous: break
            }
            controlsShow()
            return
        }
        switch command {
        case .pause:    mediaPlayer.halt()
        case .proceed:   resumePlaying()
        case .toggle: if mediaPlayer.running { mediaPlayer.halt() } else { resumePlaying() }
        // **Another device takes over** (the notice came shortly before): the picture leaves as a card. Otherwise (dashboard, other app) as usual.
        case .stop:
            if let target = handoffTargetTake() { handoffHandIn(an: target) }
            else { playerClose() }
        // Via `springe`: with position and seek guard, report immediately.
        case let .jumpOn(spot): vault(on: spot)
        case .forward:      vault(um: Double(selection.forwardSeconds))
        case .back:  vault(um: -Double(selection.backSeconds))
        case .next: nextEpisode()
        case .previous:   break
        }
        if command != .stop {
            playState.running = mediaPlayer.running
            playerPlayMarker?.setDown(playState.running)
            controlsShow()
        }
    }

    /// The name of the taking-over device if the last notice is fresh, and only once: the notice applies to exactly this stop.
    func handoffTargetTake() -> String? {
        guard let target = handoffTarget else { return nil }
        handoffTarget = nil
        return Takeover.isHandoff(hintPre: Date().timeIntervalSince(target.time)) ? target.name : nil
    }

    /// **An expired login went unnoticed.**
    ///
    /// The server answers 401, and since `try?` is used everywhere here, nothing came back: empty home page, empty grid, and the user looks for the fault on their side. macOS falls back to the login screen and says why (`Shared/AppModel.swift:789`).
    func sessionCheck(_ error: any Error) {
        guard let j = error as? JellyfinError, case let .http(status, _) = j,
              status == 401 else { return }
        signOff()
        loginStateShow(translated("Die Anmeldung gilt nicht mehr. Bitte neu anmelden."))
    }

    /// Signs out the **active** account.
    ///
    /// **If one remains, the app switches to it** instead of falling back to the server login; removing all accounts at once would be a second meaning for the same button. Which one applies afterwards is decided by `AccountBundle/entfernt(_:)` in the package.
    func signOff() {
        playerPreSwitch()
        if let older = bundle, let rest = older.removed(older.activeId) {
            bundle = rest
            let name = serverName.isEmpty ? nil : serverName
            let wasProfile = openSubpage == .profile
            saveBundle(serverName: name)
            cleanUpPostSwitch()
            sessionInSet(rest.activeOne, serverName: name)
            // Stay in the profile here as well: that an account vanished from the strip is the answer to the button.
            if wasProfile { subpageOpen(.profile, push: .without) }
            return
        }
        bundle = nil
        Task.detached { [remoteControl] in await remoteControl?.finish() }
        remoteControl = nil
        takeoverRun?.cancel()
        takeoverRun = nil
        takeoverOfferings = []
        // Leave the group, including the strip and offers of the previous account.
        sharedEnd()
        Cache.erase()
        client = nil
        addresses = nil
        loaded.removeAll()
        pagesStack.removeAll()
        openSubpage = nil
        wipe(railsStack)
        gtk_editable_set_text(OpaquePointer(passwordField), "")
        fastRun?.cancel()
        fastRun = nil
        loginStateShow("")
        serverStateShow("")
        headerRowShow(false)
        gtk_stack_set_visible_child_name(OpaquePointer(loginStep), "server")
        switchStack(pages, toward: "anmeldung")
    }

    /// Name, server and picture at the bottom of the sidebar, plus the libraries. Fetches the server's name and version afterwards; when starting from a saved session nobody has asked.
    private func serverStateFetch() {
        guard let client else { return }
        Task.detached { [self] in
            guard let info = try? await client.publicSystemInfo() else { return }
            onMainThread {
                self.serverVersion = info.version ?? ""
                if let name = info.serverName, !name.isEmpty {
                    self.serverName = name
                    gtk_label_set_text(OpaquePointer(self.profileServer), name)
                }
            }
        }
    }

    private func sessionShow(username: String, serverName: String?) {
        self.username = username
        self.serverName = serverName ?? ""
        gtk_label_set_text(OpaquePointer(profileName), username)
        gtk_label_set_text(OpaquePointer(profileServer), serverName ?? "")
        profileCircleRefresh()
    }

    /// The circles at the bottom of the sidebar: the active one in front, the others behind.
    ///
    /// **Why they are here and not only in the profile.** The strip in the profile answers "which account am I in?" only after opening it. Two circles at the bottom of the sidebar say it in passing, as in the approved design.
    ///
    /// **At most three.** The space is one row in a 220-wide sidebar; with six accounts only circles and no name would be left.
    private func profileCircleRefresh() {
        guard let profileCircle else { return }
        wipe(profileCircle)

        // **26, not 30.** The row was built for 26; with 30 the image was larger than its space and GTK clipped it at the bottom and left, so the circle was not round. The size from the design (96/72) applies to the strip in the profile, not the footer; here the row must keep its height.
        let border = 26, offset = 17, atMost = 3
        // **The ring needs its own space.** It is a shadow *outside* the circle; without an allowance the zone clipped it at the bottom. Two points all around, the stronger of the two ring widths (1.5 active, 2 beside), rounded up.
        let ring = 2
        // The active one in front, then the others in their order.
        var railsEpisode: [Session] = []
        if let bundle {
            railsEpisode = [bundle.activeOne] + bundle.accounts.filter { $0.accountKey != bundle.activeOne.accountKey }
        } else if !userIdentifier.isEmpty {
            railsEpisode = []
        }
        let visible = Array(railsEpisode.prefix(atMost))
        let width = (visible.isEmpty ? border : border + offset * (visible.count - 1))
        gtk_widget_set_size_request(profileCircle,
                                    Int32(width + 2 * ring), Int32(border + 2 * ring))

        guard !visible.isEmpty else {
            // No account group: the single image as before.
            let parts = profileCharacter(name: username.isEmpty ? "?" : username,
                                      border: border, style: "swiftly-profilbild",
                                      fontStyle: "swiftly-zeichen26")
            profileImage = parts.image
            gtk_fixed_put(asFixed(profileCircle), parts.wrapper, Double(ring), Double(ring))
            profileImageLoad(parts,
                            url: userIdentifier.isEmpty ? nil
                                                    : addresses?.user(userIdentifier, border: 60),
                            key: "leiste-\(userIdentifier)")
            return
        }

        // **Back to front.** In a `GtkFixed` the last added is on top; the active circle must cover the others so its accent ring is not clipped.
        for (i, account) in visible.enumerated().reversed() {
            // A single account looks as it always did, without a ring. The ring answers "which of several"; with one there is no such question.
            let style = visible.count == 1 ? "swiftly-profilbild"
                     : (i == 0 ? "swiftly-profilbild-aktiv" : "swiftly-profilbild-daneben")
            let parts = profileCharacter(name: account.userName, border: border, style: style,
                                      fontStyle: "swiftly-zeichen26")
            if i == 0 { profileImage = parts.image } else { gtk_widget_set_opacity(parts.wrapper, 0.55) }
            gtk_fixed_put(asFixed(profileCircle), parts.wrapper,
                          Double(ring + i * offset), Double(ring))
            profileImageLoad(parts, url: addresses?.user(account.userID, border: 60),
                            key: "leiste-\(account.userID)")
        }
    }

    private func librariesLoad() {
        guard let client else { return }
        let state = accountSwitch
        Task.detached { [self] in
            let review = (try? await client.userViews()) ?? []
            onMainThread {
                // The same entry guard as for the home page: the libraries of the previous account do not belong in the sidebar of the new one.
                guard self.accountSwitch == state else { return }
                self.librariesShow(review)
            }
        }
    }

    private func librariesShow(_ review: [Item]) {
        self.review = review
        // With the libraries known, it is settled what the titles offer, and whether "Alle" reads from one or from several.
        offeringArrived()
    }

    /// `movies` or `tvshows`: the area as a kind of the package.
    func art(_ was: Region) -> String { was == .seriesList ? "tvshows" : "movies" }

    private var offeringKey: String {
        "\(accountSwitch)|" + review.map(\.id).joined(separator: ",")
    }

    /// What the title of this area offers to choose; the rule is in the package (`SectionOffering`). **What belongs to another account does not count**; until the new one is loaded, only what the libraries alone provide is shown.
    func offering(_ was: Region) -> SectionOffering {
        let applies = offeringFor == offeringKey
        return SectionOffering.compose(art: art(was), views: review,
                                      shares: applies ? libraryShares : [:],
                                      directory: applies ? collectionDirectory : nil,
                                      playlists: applies ? playlistDirectory : nil)
    }

    /// The remembered choice of this area, checked against the offer. It is stored under the same name as the library choice before, so whoever had chosen one of two movie libraries stays there.
    func sectionSelection(_ was: Region) -> SectionSelection {
        offering(was).choice(remembered: selection.libraryPerGenre[was.identifier])
    }

    func sectionSelect(_ choice: SectionSelection, _ was: Region) {
        selection.libraryPerGenre[was.identifier] = choice.rememberValue
        selection.secure()
    }

    /// **Collections and shares of mixed libraries are loaded on demand only**, when a page needs them, and a result is valid for one minute (macOS `AppModel.offeringLoad()`): a collection created on the server appears on the next open, not only after a restart.
    func offeringLoad(then: (() -> Void)? = nil) {
        guard let client, !review.isEmpty else { then?(); return }
        let of = offeringKey
        let freshValue = offeringTime.map { Date().timeIntervalSince($0) < 60 } ?? false
        guard offeringFor != of || !freshValue else { then?(); return }
        if let then { offeringWaiting.append(then) }
        guard offeringRuns != of else { return }
        offeringRuns = of
        let state = review
        Task.detached { [self] in
            // Separate tasks instead of `async let` (see `besideFrom(_:)`).
            let shares = besideFrom { await client.libraryShares(views: state) }
            let directory = besideFrom { () async -> CollectionDirectory? in
                let withHidden = (try? await client.userViews(hidden: true)) ?? state
                if CollectionDirectory.hidden(visible: state, withHidden: withHidden) {
                    return .empty
                }
                return try? await client.collectionDirectory(viewList: withHidden)
            }
            // A server without an answer shows no playlists; that must not hold back collections.
            let playlists = besideFrom { () async -> PlaylistDirectory? in try? await client.playlistDirectory() }
            let newShares = await shares.value
            let newDirectory = await directory.value
            let newPlaylists = await playlists.value
            onMainThread {
                if self.offeringRuns == of { self.offeringRuns = nil }
                // The account changed meanwhile: the result belongs to no one any more.
                guard of == self.offeringKey else { return }
                self.libraryShares = newShares
                self.playlistDirectory = newPlaylists
                // **Failed is not empty.** Without an answer the state stays invalid, and the next page asks again.
                if let newDirectory {
                    self.collectionDirectory = newDirectory
                    self.offeringFor = of
                    self.offeringTime = Date()
                }
                self.offeringArrived()
                let waitingOnes = self.offeringWaiting
                self.offeringWaiting = []
                for w in waitingOnes { w() }
            }
        }
    }

    /// **Collections and mixed libraries arrive later.** If that changes what "Alle" reads or what may be chosen, it reloads, keyed on the source, not on the count.
    func offeringArrived() {
        for was in [Region.movies, .seriesList] {
            titleSelectionDraw(was)
            guard loaded.contains(was), let alt = gridSource[was] else { continue }
            if alt != sourceKey(was) {
                chipsFill(was)
                gridLoad(was)
            }
        }
    }

    /// What the grid page of this area reads from. `nil`: this area has nothing, or it shows the collections.
    func shelfSource(_ was: Region) -> ShelfSource? {
        switch was {
        case .collection:
            guard let s = openCollection else { return nil }
            return ShelfSource(parent: s.item.id, art: s.art, collection: true)
        case .movies, .seriesList:
            let an = offering(was)
            switch sectionSelection(was) {
            case .all:
                // From one library as before; from several, filtered to one entry per title (`TitleFilter`).
                return an.hasInventory
                    ? ShelfSource(parent: an.allOut, art: art(was),
                                  onlyOut: an.allOut == nil ? an.allSources : [])
                    : nil
            case .library(let id):
                return ShelfSource(parent: id, art: art(was))
            case .collections, .playlists:
                return nil
            }
        default:
            return nil
        }
    }

    private func sourceKey(_ was: Region) -> String {
        if (was == .movies || was == .seriesList), sectionSelection(was) == .collections {
            return "sammlungen|" + (collectionDirectory?.collections(art: art(was))
                .map(\.id).joined(separator: ",") ?? "")
        }
        if (was == .movies || was == .seriesList), sectionSelection(was) == .playlists {
            return "wiedergabelisten|" + (playlistDirectory?.playlists(art: art(was))
                .map(\.id).joined(separator: ",") ?? "")
        }
        return shelfSource(was)?.key ?? "-"
    }

    /// **Open a collection as a subpage** (macOS `CollectionDetailPage`).
    ///
    /// Arrow, name, filter and sort, grid: the grid page with a collection as the source. Default sort by year, ascending; filter and sort start fresh each time.
    ///
    /// `art` is `nil` for a collection that was a tile in a list (see `openIt(_:)`): then no kind, so everything in it.
    func collectionOpen(_ collection: Item, art: String?) {
        // From within a collection the way back stays the original one.
        if section != .collection { collectionOrigin = section }
        openCollection = (collection, art)
        collectionSorting = .erscheinung
        collectionFilter = .all
        if let small = barTitle[.collection] {
            gtk_label_set_text(OpaquePointer(small), collection.name)
        }
        if collectionTitle != nil {
            gtk_label_set_text(OpaquePointer(collectionTitle), collection.name)
        }
        // **Reload, do not show the old one**; otherwise the titles of the first collection would appear under the second.
        loaded.remove(.collection)
        pagesStack[.collection] = []
        gridItems[.collection] = []
        if let grid = gridField[.collection] { gridFill(grid, []) }
        chipsFill(.collection)
        show(.collection)
    }

    /// The collection page's arrow: back to where it came from.
    func collectionClose() {
        show(collectionOrigin)
    }

    /// **A genre as its own page**: the same grid as library, watchlist and search, with the genre name as the title.
    ///
    /// Sorted by "recently added": whoever taps a genre usually looks for what is new. The rule is `title(genre:)` in the package.
    func genreOpen(_ name: String) {
        openGenre = name
        if let small = barTitle[.genre] {
            gtk_label_set_text(OpaquePointer(small), name)
        }
        if genreTitle != nil {
            gtk_label_set_text(OpaquePointer(genreTitle), name)
        }
        loaded.remove(.genre)
        pagesStack[.genre] = []
        show(.genre)
    }

    /// **Which sidebar row is highlighted.**
    ///
    /// Not only which area, but whether any is. If a subpage (profile, settings, playback) or a library is open, the highlight belongs to no area row; otherwise "Start" lights up while the profile is shown. On macOS the same condition sits on the row itself (`section == fall && !bibliothekOffen && !inAccount`).
    /// Also carries the server name into all page headers; it arrives only with `publicSystemInfo`, by which time the pages already exist.
    func serverRowsDraw() {
        for (_, row) in serverRows {
            gtk_label_set_text(OpaquePointer(row), serverName)
            gtk_widget_set_visible(row, serverName.isEmpty ? 0 : 1)
        }
    }

    func sectionRowsDraw() {
        let nobody = openSubpage != nil
        // The collection lies in the area it came from; that area's row stays.
        let active = section == .collection ? collectionOrigin : section
        for (fall, button) in sectionButtons {
            let an = !nobody && fall == active
            if an { gtk_widget_add_css_class(button, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(button, "swiftly-aktiv") }
            help(button, selected: an)
        }
        if let profileRow {
            if openSubpage != nil { gtk_widget_add_css_class(profileRow, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(profileRow, "swiftly-aktiv") }
        }
    }

    func homeLoad() {
        guard let client else { return }
        lastLoaded = Date()
        // **What the server does not know yet is sent now.** Not on a timer of its own: here the server is demonstrably reachable, because rows are fetched from it right below. The same place as on macOS, where it hangs on the connection check.
        let account = userIdentifier
        Task.detached { await PostReportSlip.submit(client, account: account) }
        // **Whose answer is this?** Switching drops the old client, but a request already in flight still comes back and would overwrite the new account's rows with the old one's. The counter is the entry guard: if it no longer matches when the answer arrives, the answer belongs to no one.
        let state = accountSwitch
        // **"Lade …" only the first time.** On a reload (return to foreground, closing the player) everything is already there; throwing it away and replacing it with a word looked like an app restart, although usually only a progress bar changes. It is replaced only when the new rows are there.
        if gtk_widget_get_first_child(railsStack) == nil {
            // **No spinner, no "Lade …":** the rows stand in their final shape and dissolve when the data arrives.
            append(railsStack, railsPlaceholder(margin: Theme.edgeSpacing))
        }

        // Read the choice before the thread: `selection` belongs to the main thread.
        let disconnected = selection.newArrivalsDisconnected
        let railsEpisode = selection.startRails
        let hidden = selection.startOut
        let genres = selection.startGenres
        let asChips = selection.genreChips
        let librarySelection = selection.startLibraries
        Task.detached { [self] in
            // **The error is read here, not swallowed.** The home page reloads on every return to the foreground and is therefore where an expired login is noticed first; before, nothing came back and the page stayed empty.
            //
            // **Only for the account that is still active.** The home page often loads twice in quick succession (window return, player closed). If both came back with 401, the first signed the account out and switched to the next, and the second, which still belonged to the old one, signed out **the next** one as well.
            do { _ = try await client.resumeItems(limit: 1) }
            catch {
                onMainThread {
                    guard self.accountSwitch == state, self.client === client else { return }
                    self.sessionCheck(error)
                }
            }
            // **Only a library that exists**: since the title menu, "alle" or "sammlungen" can also be stored (macOS `AppModel.selectedLibrary(art:)`).
            let filmBib = libraries(for: .movies).first { $0.id == selectedLibrary[.movies] }?.id
                ?? libraries(for: .movies).first?.id
            let seriesBib = libraries(for: .seriesList).first { $0.id == selectedLibrary[.seriesList] }?.id
                ?? libraries(for: .seriesList).first?.id
            // **One rule for all platforms**: `HomeLoader` in the package.
            //
            // This used to be a separate copy of `HomeModel.load`, and it had already drifted: "Nächste Folge" kept the titles already in "Weiterschauen". Now the package fetches the rows the same way for Apple, Linux/Windows and Android; here they are only arranged and displayed.
            let home = await HomeLoader.load(from: client, .init(
                disconnected: disconnected, filmLibrary: filmBib, seriesLibrary: seriesBib,
                genres: asChips ? nil : genres))
            // **The library rows run in parallel**, all at once with one request per row (`HomeLoader.libraryRails`); one that no longer exists or is empty silently drops out.
            let libraries = librarySelection.isEmpty ? [] :
                await HomeLoader.libraryRails(from: client, choice: librarySelection)
            let content: [StartRail: (RailsKind, [Item])] = [
                .continueWatching: (.continueWatching, home.continueWatching ?? []),
                .nextEpisode: (.next, home.nextEpisode ?? []),
                .newArrivals:   (.new, home.recent ?? []),
                .newMovies:     (.new, home.newMovies ?? []),
                .newSeries:    (.new, home.newSeries ?? []),
            ]
            var collected: [StartRailsRow] = StartRailsEpisode
                .visible(stored: railsEpisode, from: Set(hidden), disconnected: disconnected)
                .compactMap { r in
                    guard let (art, items) = content[r], !items.isEmpty else { return nil }
                    return (translated(r.railsTitle), art, items, nil)
                }
            // Between the fixed rows and the genres, as on Apple. The header opens the library or collection.
            collected += libraries.map { r in
                (r.name, .new, r.items,
                 librarySelection.first { $0.id == r.id }?.item ?? Item(id: r.id, name: r.name))
            }
            collected += home.genreRails.map { ($0.name, .new, $0.items, nil) }
            let rails = collected

            onMainThread {
                guard self.accountSwitch == state else { return }
                self.genreChipsShow(asChips ? genres : [])
                self.railsShow(rails, disrupted: home.disrupted)
            }
        }
    }

    /// Movies and series. **With kind and recursive**, for the reason given in `JellyfinClient.items`: otherwise a series library returns the virtual folders instead of the series.
    /// **Load more while paging** instead of fetching 500 once.
    ///
    /// 500 was a number at which it was assumed to be enough; with a larger collection the rest is simply missing. macOS pulls the next page when the third-to-last row becomes visible (`LibraryModel.swift:82`); here it hangs on the bottom edge of the scroller, which means the same and is a signal GTK provides anyway.
    private func gridLoadMore(_ was: Region) {
        guard !gridLoads.contains(was) else { return }
        let already = (gridItems[was] ?? []).count
        guard already > 0 else { return }
        // For filtered lists, this counts how far the raw pages have been read.
        if gridFilter[was] != nil, let raw = gridRaw[was] {
            guard raw.offset < raw.total else { return }
        } else {
            guard ListRules.stillMorePresent(loaded: already, total: gridTotal[was] ?? 0)
            else { return }
        }
        gridLoad(was, since: already)
    }

    private func gridLoad(_ was: Region, since: Int = 0, reach: Int? = nil) {
        guard let client else { return }
        // **Movies and series ask for collections and mixed libraries** in parallel; the page does not wait for it (`LibraryView.load()` on macOS).
        if since == 0, was == .movies || was == .seriesList {
            offeringLoad()
            titleSelectionDraw(was)
            gridSource[was] = sourceKey(was)
            // **"Sammlungen" loads nothing**: the list is in the directory.
            if sectionSelection(was) == .collections || sectionSelection(was) == .playlists {
                collectionsShow(was)
                return
            }
        }
        gridLoads.insert(was)
        // **The old tiles stay until the new ones are there.** Here the grid was emptied first and the placeholder shown, below the still-standing grid, and on every click on a chip.
        gridJob[was, default: 0] += 1
        let job = gridJob[was] ?? 0
        if since == 0, (gridItems[was] ?? []).isEmpty {
            gridLoaderShow(was, true)
        }
        let f = filterFrom(was)
        let sort = sortingFrom(was)
        let state = accountSwitch

        // **Movies, series and collection read from a `ShelfSource`**: a library, "Alle" across the libraries, or a collection. The differences (kind, recursive, direction) are in the package so macOS, TV, Android and Linux issue the same queries.
        if was == .movies || was == .seriesList || was == .collection {
            guard let source = shelfSource(was) else {
                // Two cases look the same here: a server without a library of this kind, and one that did not answer at all. They differ in whether any libraries are known.
                gridLoads.remove(was)
                gridLoaderShow(was, false)
                gridItems[was] = []
                if let grid = gridField[was] { gridFill(grid, []) }
                if let figure = numberField[was] { gtk_widget_set_visible(figure, 0) }
                gridStateShow(was, disrupted: review.isEmpty, empty: true)
                return
            }
            if source.isFiltering {
                filteredLoad(was, source: source, since: since, reach: reach, job: job, filter: f,
                             sorting: sort, state: state, client: client)
                return
            }
            gridFilter[was] = nil
            gridRaw[was] = nil
            // "By name" pages come from the naturally sorted list; the first page fetches it
            // fresh, later pages reuse it.
            let cachedNatural = sort == .name && since > 0 ? gridNatural[was] : nil
            Task.detached { [self] in
                let answer: ItemsResponse?
                if sort == .name {
                    var list = cachedNatural
                    if list == nil {
                        list = try? await client.naturalList(
                            parentID: source.parent, sortOrder: source.bearing(.name),
                            filters: f.jellyfinFilter, isWatched: f.isWatched,
                            recursive: source.recursive, includeItemTypes: source.types)
                        if let fresh = list { onMainThread { self.naturalStore(was, fresh) } }
                    }
                    if let list {
                        answer = try? await client.naturalPage(list, since: since, count: reach ?? 100)
                    } else {
                        answer = nil
                    }
                } else {
                    answer = try? await client.items(parentID: source.parent,
                                                      limit: reach ?? 100,
                                                      startIndex: since,
                                                      sortBy: sort.inputField,
                                                      sortOrder: source.bearing(sort),
                                                      filters: f.jellyfinFilter,
                                                      isWatched: f.isWatched,
                                                      recursive: source.recursive,
                                                      includeItemTypes: source.types)
                }
                onMainThread {
                    self.gridResponse(was, since: since, job: job, state: state,
                                       items: answer?.items ?? [],
                                       total: answer.map { $0.totalRecordCount },
                                       disrupted: answer == nil)
                }
            }
            return
        }

        // **The watchlist is not a library but a filter.** It queries both kinds and lets the server filter on `IsFavorite`, taken literally from `AppModel.remembered(art:sorting:since:)` on macOS.
        let genres: [String]
        switch was {
        // What the pill says: movie and series used to be fixed here, and separating them was not possible on the server side.
        case .watchlist: genres = savedGenre.types
        default:      genres = ["Movie", "Series"]
        }
        // **A genre spans all libraries**, like the watchlist: it is a property, not a place. And it sorts by "recently added", not by the chosen field: whoever taps a genre usually looks for what is new.
        let genre = was == .genre ? openGenre : nil
        Task.detached { [self] in
            // **The watchlist once per work** (`JellyfinClient.rememberedItems`), counted in works; `since` remains the number of loaded tiles.
            let answer: ItemsResponse?
            if was == .watchlist {
                answer = try? await client.rememberedItems(types: genres, sortBy: sort.inputField,
                                                          sortOrder: sort.bearing,
                                                          startIndex: since, limit: reach ?? 100)
            } else {
                answer = try? await client.items(parentID: nil,
                                                  // 200 at once for a genre, otherwise 100 per page (`GenreView.swift:70`).
                                                  limit: reach ?? (genre != nil ? 200 : 100),
                                                  startIndex: since,
                                                  sortBy: genre != nil ? "DateCreated" : sort.inputField,
                                                  sortOrder: genre != nil ? "Descending"
                                                                          : sort.bearing,
                                                  filters: f.jellyfinFilter,
                                                  isWatched: f.isWatched,
                                                  recursive: true,
                                                  includeItemTypes: genres,
                                                  genres: genre.map { [$0] } ?? [])
            }
            onMainThread {
                self.gridResponse(was, since: since, job: job, state: state,
                                   items: answer?.items ?? [],
                                   total: answer.map { $0.totalRecordCount },
                                   disrupted: answer == nil)
            }
        }
    }

    // MARK: Letter strip

    /// The strip in the right margin of a grid page; 24 already fit it, so the grid does not
    /// move. The topmost title's letter follows the scrolling.
    private func alphabetStripBuild(_ was: Region, over: Widget, scroller: Widget!) {
        let strip = AlphabetStrip()
        gtk_widget_set_margin_top(strip.widget, Int32(Theme.contentTop + 96))
        gtk_widget_set_margin_bottom(strip.widget, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(strip.widget, max(0, (Int32(Theme.edgeSpacing) - AlphabetStrip.width) / 2))
        strip.jump = { [weak self] letter in self?.alphabetJump(was, letter) }
        gtk_overlay_add_overlay(OpaquePointer(over), strip.widget)
        alphabetStrips[was] = strip
        gridScrollers[was] = scroller
        if let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller)) {
            signalRaw(UnsafeMutableRawPointer(adjustment), "value-changed") { [weak self] in
                self?.alphabetTopUpdate(was)
            }
        }
    }

    /// Shows the strip where it means something (switched on, "By name", a grid of titles),
    /// hides it otherwise.
    func alphabetRailUpdate(_ was: Region) {
        guard let strip = alphabetStrips[was] else { return }
        let titles = was == .collection
            || (sectionSelection(was) != .collections && sectionSelection(was) != .playlists)
        let on = selection.alphabetShown && sortingFrom(was) == .name && titles
        let height = gridScrollers[was].map { Double(gtk_widget_get_height($0)) } ?? 0
        strip.show(on ? gridAlphabet[was] : nil, height: height - Double(Theme.contentTop + 96 + Theme.edgeSpacing))
        alphabetTopUpdate(was)
    }

    /// Whether more pages are left (`gridLoadMore`'s rule).
    private func gridHasMore(_ was: Region) -> Bool {
        if gridFilter[was] != nil, let raw = gridRaw[was] { return raw.offset < raw.total }
        return ListRules.stillMorePresent(loaded: (gridItems[was] ?? []).count, total: gridTotal[was] ?? 0)
    }

    /// **Jumps to the first title of a letter**, loading up to it in steps sized by where
    /// the letter starts in the list.
    private func alphabetJump(_ was: Region, _ letter: String) {
        guard let alphabet = gridAlphabet[was] else { return }
        let items = gridItems[was] ?? []
        if let i = alphabet.target(for: letter, inLoaded: items.map { ($0.name, $0.sortName) }) {
            pendingLetter[was] = nil
            gridScroll(was, to: i)
            return
        }
        guard gridHasMore(was), !items.isEmpty else {
            pendingLetter[was] = nil
            if !items.isEmpty { gridScroll(was, to: items.count - 1) }
            return
        }
        let start = alphabet.entries.first { $0.letter == letter }?.first ?? 0
        pendingLetter[was] = letter
        gridLoad(was, since: items.count, reach: max(100, start - items.count + 100))
    }

    /// A short glide that puts the tile's row under the bar.
    ///
    /// **Measured only once the tile has its place.** Right after a page is appended the new
    /// tiles have no allocation yet; their bounds read as zero and the glide went to the top
    /// or nowhere useful. So it waits (up to a second, frame by frame) for a real height, and
    /// only then glides.
    private func gridScroll(_ was: Region, to index: Int) {
        guard let grid = gridField[was], let scroller = gridScrollers[was],
              let content = gtk_scrolled_window_get_child(OpaquePointer(scroller)),
              let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
        else { return }
        var measured = false
        runningCount(on: scroller, duration: 1.0, linear: true, step: { _ in
            guard !measured,
                  let kind = gtk_flow_box_get_child_at_index(OpaquePointer(grid), Int32(index))
            else { return }
            var r = graphene_rect_t()
            guard gtk_widget_compute_bounds(unsafeBitCast(kind, to: Widget.self), content, &r) != 0,
                  r.size.height > 0 else { return }
            measured = true
            let atMost = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            let target = min(max(Double(r.origin.y) - Double(Theme.headerBarHeight) - 12, 0), max(atMost, 0))
            let from = gtk_adjustment_get_value(adjustment)
            runningCount(on: scroller, duration: 0.25, step: { t in
                gtk_adjustment_set_value(adjustment, from + (target - from) * t)
            }, done: {})
        }, done: {})
    }

    /// The letter of the topmost title under the bar, into the strip.
    private func alphabetTopUpdate(_ was: Region) {
        guard let strip = alphabetStrips[was], gtk_widget_get_visible(strip.widget) != 0,
              let grid = gridField[was], let scroller = gridScrollers[was],
              let content = gtk_scrolled_window_get_child(OpaquePointer(scroller)),
              let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
        else { return }
        var r = graphene_rect_t()
        guard gtk_widget_compute_bounds(grid, content, &r) != 0 else { return }
        let y = gtk_adjustment_get_value(adjustment) + Double(Theme.headerBarHeight) + 20 - Double(r.origin.y)
        guard let kind = gtk_flow_box_get_child_at_pos(OpaquePointer(grid), 10, Int32(max(y, 0))) else { return }
        let index = Int(gtk_flow_box_child_get_index(kind))
        let items = gridItems[was] ?? []
        guard items.indices.contains(index) else { return }
        strip.highlight(AlphabetIndex.letter(name: items[index].name, sortName: items[index].sortName))
    }

    /// The naturally sorted list of a grid and its letter strip, on the main thread.
    private func naturalStore(_ was: Region, _ list: [Item]) {
        gridNatural[was] = list
        gridAlphabet[was] = AlphabetIndex(titles: list.map { ($0.name, $0.sortName) })
        alphabetRailUpdate(was)
    }

    /// An answer into the grid, on the main thread.
    private func gridResponse(_ was: Region, since: Int, job: Int, state: Int,
                               items: [Item], total: Int?, disrupted: Bool,
                               alreadyFiltered: Bool = false) {
        // Here too: an answer of the previous account is discarded instead of being appended to its titles.
        guard accountSwitch == state else { return }
        // A later choice has overtaken this answer.
        guard gridJob[was] == job else { return }
        gridLoads.remove(was)
        gridLoaderShow(was, false)
        guard let grid = gridField[was], let figure = numberField[was] else { return }
        // **Append deduplicated** (`ListRules.append`). The server may add something between two pages; then a title shifts back one place and would appear a second time on the next page. On GTK the tile would simply be in the grid twice.
        let before = gridItems[was] ?? []
        if !disrupted || since == 0 {
            gridItems[was] = since == 0 ? items : ListRules.append(
                items, an: before)
        }
        // **A failed reload keeps the total count.** Otherwise the list would count as complete afterwards, and neither the edge nor "Erneut versuchen" would ever fetch the next page.
        let loadMoreDisturbed = disrupted && since > 0
        let numberValue = loadMoreDisturbed
            ? (gridTotal[was] ?? (gridItems[was] ?? []).count)
            : (total ?? (gridItems[was] ?? []).count)
        gridTotal[was] = numberValue
        // **Reloading only appends.** Before, every page rebuilt all tiles: with 300 titles, 300 tiles with images just to add 100, and the images flickered in again. `append` leaves the front part alone, so the rest is enough.
        let now = gridItems[was] ?? []
        if since > 0, gridCount(grid) == before.count,
           now.count >= before.count, now.prefix(before.count).map(\.id) == before.map(\.id) {
            gridAppend(grid, Array(now.dropFirst(before.count)))
        } else {
            gridFill(grid, now)
        }
        gtk_label_set_text(OpaquePointer(figure), String(numberValue))
        gtk_widget_set_visible(figure, numberValue > 0 ? 1 : 0)
        // The strip follows sort and library; a jump that waited for this page goes on.
        if since == 0 { alphabetRailUpdate(was) }
        if let letter = pendingLetter[was], !disrupted { alphabetJump(was, letter) }
        // **After an account switch the new content arrives staggered**, like the home page rows (macOS: `AccountSwitchPart`, index 1).
        if since == 0, gridSeasons.remove(was) != nil, !(gridItems[was] ?? []).isEmpty {
            railOccur(grid, number: 1)
        }
        // **Failed is not empty**: a failed request says "Server ist abgetaucht", not "hier ist nichts".
        let nothing = (gridItems[was] ?? []).isEmpty
        gridStateShow(was, disrupted: disrupted && nothing, empty: nothing)
        // **A failed reload says so too.** Before, the grid just ended as if the library were complete. It appears under the tiles, not instead of them; what is there stays.
        if loadMoreDisturbed, !nothing, let inputField = emptyField[was] {
            wipe(inputField)
            append(inputField, disturbHint(top: 24) { [weak self] in self?.gridLoadMore(was) })
            gtk_widget_set_visible(inputField, 1)
        }
    }

    /// **From several libraries, one entry per title** (macOS `LibraryModel.filteredLoad`/`fill`).
    ///
    /// First the IDs of the chosen libraries, with the same filters (`TitleFilter`), which also fixes the count. Then pages without `ParentId` until something remains: a page can consist almost entirely of duplicates, and then no new tile would appear that the next reload could hang on.
    private func filteredLoad(_ was: Region, source: ShelfSource, since: Int, reach: Int? = nil, job: Int,
                              filter f: LibraryFilter, sorting sort: Sorting,
                              state: Int, client: JellyfinClient) {
        let pagesSize = 60
        let oldFilter = since == 0 ? nil : gridFilter[was]
        let start = since == 0 ? 0 : (gridRaw[was]?.offset ?? 0)
        let cachedNatural = sort == .name && since > 0 ? gridNatural[was] : nil
        Task.detached { [self] in
            // "By name": the raw pages are slices of the naturally sorted list.
            var natural: [Item]? = cachedNatural
            if sort == .name, natural == nil {
                natural = try? await client.naturalList(
                    parentID: nil, sortOrder: source.bearing(.name), filters: f.jellyfinFilter,
                    isWatched: f.isWatched, recursive: source.recursive,
                    includeItemTypes: source.types)
                if let fresh = natural { onMainThread { self.naturalStore(was, fresh) } }
            }
            var filterRef: TitleFilter
            if let oldFilter {
                filterRef = oldFilter
            } else {
                let listen = try? await client.titleFilter(source, filters: f.jellyfinFilter,
                                                          isWatched: f.isWatched)
                guard let listen else {
                    onMainThread {
                        self.gridResponse(was, since: since, job: job, state: state,
                                           items: [], total: nil, disrupted: true)
                    }
                    return
                }
                filterRef = listen
            }
            var new: [Item] = []
            var offset = start
            var raw = 0
            var failed = false
            // The first request may be larger: a jump in the letter strip asks for more.
            var count = max(pagesSize, reach ?? pagesSize)
            repeat {
                let fetched: ItemsResponse?
                if let natural {
                    fetched = try? await client.naturalPage(natural, since: offset, count: count)
                } else {
                    fetched = try? await client.items(parentID: nil,
                                                       limit: count,
                                                       startIndex: offset,
                                                       sortBy: sort.inputField,
                                                       sortOrder: source.bearing(sort),
                                                       filters: f.jellyfinFilter,
                                                       isWatched: f.isWatched,
                                                       recursive: source.recursive,
                                                       includeItemTypes: source.types)
                }
                guard let page = fetched else { failed = true; break }
                count = pagesSize
                new += filterRef.seven(page.items)
                offset += page.items.count
                raw = page.totalRecordCount
                if page.items.isEmpty { break }
            } while new.count < pagesSize / 2 && offset < raw
            let readyFilter = filterRef
            let (new_, offset_, raw_, failed_) = (new, offset, raw, failed)
            onMainThread {
                let (new, offset, raw, failed) = (new_, offset_, raw_, failed_)
                guard self.accountSwitch == state, self.gridJob[was] == job else { return }
                if !failed {
                    self.gridFilter[was] = readyFilter
                    self.gridRaw[was] = (offset, raw)
                }
                self.gridResponse(was, since: since, job: job, state: state,
                                   items: new, total: readyFilter.total,
                                   disrupted: failed && new.isEmpty)
            }
        }
    }

    /// **Searches while typing, not on Enter.**
    ///
    /// On macOS the search hangs on `.task(id: term)`: from two characters it waits 280 ms and cancels as soon as typing continues. A keypress as trigger would be a deviation without reason; input type and distance are the same as there.
    ///
    /// GTK has no `Task.isCancelled` for signals, so a counter is kept: after the wait only the latest one searches. The comparison runs through `onMainThread`, on the same thread that increments, otherwise it would be a race.
    private func searchTriggered() {
        searchTick += 1
        let mine = searchTick
        let term = text(searchField).trimmingCharacters(in: .whitespacesAndNewlines)
        guard DisplayRules.searchTermFits(term) else {
            gridFill(searchGrid, [])
            gtk_widget_set_visible(searchEmpty, 0)
            gtk_widget_set_visible(searchDisturbance, 0)
            seerrHitShow([])
            // Empty field means "Zuletzt gesucht" comes back.
            searchHistoryShow()
            return
        }
        Task.detached { [self] in
            // 300 ms, as in `Sources/macOS/SearchView.swift:188`.
            try? await Task.sleep(nanoseconds: 300_000_000)
            onMainThread {
                guard self.searchTick == mine else { return }
                self.searching(mine)
            }
        }
    }

    /// **Own server first, Seerr afterwards, in two steps.**
    ///
    /// Waiting for both at once would leave the own library empty for as long as a foreign service needs. Seerr runs on another machine and may take seconds or not answer; the own results arrive in milliseconds and are shown at once. The row below follows when it arrives.
    ///
    /// **The counter is also checked after the wait**, not only before. For the own server this had no effect for a long time because it answers faster than anyone types. Seerr does not: without the check, the answer for "Herr" paints its results under "Herr der Ringe".
    /// Rebuilds "Zuletzt gesucht" and hides the block when it is empty or a search is running.
    private var searchHistoryKey: String {
        SearchHistory.key(account: bundle?.activeOne.accountKey)
    }

    /// "Zuletzt gesucht" of the active account. If it has no entry, it inherits the former shared one once (as on macOS).
    func searchHistoryRead() -> String {
        let key = searchHistoryKey
        if let raw = selection.searchHistoryPerAccount[key] { return raw }
        guard key != SearchHistory.key else { return selection.searchHistory }
        selection.searchHistoryPerAccount[key] = selection.searchHistory
        return selection.searchHistory
    }

    func searchHistorySet(_ new: String) {
        let key = searchHistoryKey
        if key == SearchHistory.key { selection.searchHistory = new }
        selection.searchHistoryPerAccount[key] = new
    }

    /// Term, results and failure belong to the previous account (macOS: `onChange` of `accountSwitch` in `SearchView`).
    func discardSearchResults() {
        guard searchGrid != nil else { return }
        searchTick += 1
        if searchField != nil { gtk_editable_set_text(OpaquePointer(searchField), "") }
        gridFill(searchGrid, [])
        ownHitEmpty = false
        seerrHitShow([])
        if searchEmpty != nil { gtk_widget_set_visible(searchEmpty, 0) }
        if searchDisturbance != nil { wipe(searchDisturbance); gtk_widget_set_visible(searchDisturbance, 0) }
        searchHistoryShow()
    }

    func searchHistoryShow() {
        guard searchHistoryList != nil else { return }
        let phrases = SearchHistory.list(searchHistoryRead())
        let fieldEmpty = text(searchField).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        gtk_widget_set_visible(searchHistoryBlock, (fieldEmpty && !phrases.isEmpty) ? 1 : 0)
        if searchHint != nil {
            gtk_widget_set_visible(searchHint, (fieldEmpty && phrases.isEmpty) ? 1 : 0)
        }
        wipe(searchHistoryList)
        for (spot, word) in phrases.enumerated() {
            if spot > 0 {
                let stroke: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
                gtk_widget_add_css_class(stroke, "swiftly-trennlinie")
                gtk_widget_set_size_request(stroke, -1, 1)
                gtk_widget_set_margin_start(stroke, 48)
                append(searchHistoryList, stroke)
            }
            let row = valuesRow(symbol: "document-open-recent-symbolic", title: word) {
                [weak self] in
                guard let self else { return }
                gtk_editable_set_text(OpaquePointer(self.searchField), word)
                self.searchTick += 1
                self.searching(self.searchTick)
            }
            append(searchHistoryList, row)
        }
    }

    /// - Parameter merken: Whether the term lands in "Zuletzt gesucht".
    ///
    ///   **Only on submit, not while typing.** The call used to be unconditional here, and this function is also called by the timer after every typing pause: typing "Ga", "Gam", "Game" left three history entries. On macOS `merken` hangs only on the field's `completion` (`SearchView.swift:101`).
    private func searching(_ mine: Int, remember: Bool = false) {
        guard let client else { return }
        let term = text(searchField).trimmingCharacters(in: .whitespacesAndNewlines)
        // **The threshold comes from the package**: `DisplayRules` requires two characters, trimmed. This used `!term.isEmpty`, so a single letter triggered a server request, unlike on macOS. The timer checks it too, but Enter and a click on a history entry bypass it.
        guard DisplayRules.searchTermFits(term) else {
            gridFill(searchGrid, [])
            searchHistoryShow()
            return
        }
        if remember {
            searchHistorySet(SearchHistory.remember(term, in: searchHistoryRead()))
            selection.secure()
        }
        searchHistoryShow()
        let seerr = seerrClient
        Task.detached { [self] in
            let answer = try? await client.search(term)
            let hit = ListRules.withoutDouble(answer ?? [])
            onMainThread {
                guard self.searchTick == mine else { return }
                self.gridFill(self.searchGrid, hit, inquiry: true)
                self.searchDisturbanceShow(answer == nil, mine: mine)
                // **Both empty, not only the library.** With only `hit.isEmpty`, this branch would win as soon as the own server has nothing, and "Nichts gefunden" would stand above the Seerr results, exactly the case the integration exists for. The Seerr part answers later and fades in.
                // Failed does not count as empty; otherwise the Seerr part would put "Nichts gefunden" above the failure.
                self.ownHitEmpty = answer != nil && hit.isEmpty
                gtk_widget_set_visible(self.searchEmpty,
                                       self.ownHitEmpty && self.seerrHitEmpty ? 1 : 0)
                self.seerrHitShow([])
            }
            guard let seerr else { return }
            let foreignOnes = await seerr.searching(term)
            onMainThread {
                guard self.searchTick == mine else { return }
                self.seerrHitShow(foreignOnes)
                // Found is found, even if it is elsewhere; as on macOS, Seerr results also displace the failure.
                if !foreignOnes.isEmpty {
                    gtk_widget_set_visible(self.searchEmpty, 0)
                    gtk_widget_set_visible(self.searchDisturbance, 0)
                }
            }
        }
    }

    private func searchDisturbanceShow(_ disrupted: Bool, mine: Int) {
        wipe(searchDisturbance)
        gtk_widget_set_visible(searchDisturbance, disrupted ? 1 : 0)
        guard disrupted else { return }
        append(searchDisturbance, disturbState { [weak self] in
            guard let self, self.searchTick == mine else { return }
            self.searching(mine)
        })
    }

    /// **Genres as chips, at the very top**: an entry point, not content; a click opens the genre.
    ///
    /// **Rectangular, not round.** Corner like a button; round is for images. The names come from the server and therefore never pass through translation.
    private func genreChipsShow(_ names: [String]) {
        genreChips = names
    }

    private func genreChipRow() -> Widget! {
        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_margin_start(rail, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(rail, Int32(Theme.edgeSpacing))
        for name in genreChips {
            let chip: Widget! = gtk_button_new_with_label(name)
            gtk_widget_add_css_class(chip, "swiftly-gattungschip")
            signal(chip, "clicked") { [weak self] in self?.genreOpen(name) }
            append(rail, chip)
        }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), rail)
        gtk_widget_set_margin_top(rail, 4)
        gtk_widget_set_margin_bottom(rail, 4)
        // 34 high and 120 each: `Blätterreihe(widthJePiece: 120, imageHeight: 34)` on macOS. **Fixed height 42** (4 + 34 + 4), for the same reason as for the row.
        let area = sheetsArea(scroller, imageHeight: 34, piece: 120)
        gtk_widget_set_size_request(area, -1, 42)
        gtk_widget_set_vexpand(area, 0)
        return area
    }

    func railsShow(_ rails: [StartRailsRow], disrupted: Bool = false,
                      staggered: Bool = false) {
        // **While the profile picture flies, the rows wait** (iOS "wechsel 5"): they arrive only after the swap, staggered.
        if let transition = accountTransition, transition.holdRails {
            transition.waitingRails = (rails, disrupted)
            return
        }
        let staggered = staggered || accountTransitionSeasonPostGl
        accountTransitionSeasonPostGl = false
        lastStartRail = rails.first?.2 ?? []
        wipe(railsStack)
        // **The chips come along** as the first in the sequence, as on macOS (`genreChips.railEntrance(0, …)`). Before, after an account switch they appeared abruptly while the rows below flew in.
        var tick = 0
        if !genreChips.isEmpty {
            let chips = genreChipRow()
            append(railsStack, chips)
            if staggered { railOccur(chips, number: 0) }
            tick = 1
        }
        // **Failed is not empty**: a server that does not answer gets the server wording and "Erneut versuchen", not "Hier ist noch nichts". A wrong diagnosis sends the user to the server instead of the network.
        if rails.isEmpty, disrupted {
            append(railsStack, disturbState(top: 120) { [weak self] in
                self?.homeLoad()
            })
            return
        }
        guard !rails.isEmpty else {
            append(railsStack,
                      emptyState("mail-inbox-symbolic", translated("Hier ist noch nichts"),
                                  translated("Sobald der Server Titel hat, stehen sie hier."),
                                  top: 120))
            return
        }
        for (i, (title, art, titleList, header)) in rails.enumerated() {
            let rail = railBuild(title: title, art: art, items: titleList,
                                   header: header.map { entryRecord in
                                       { [weak self] in self?.collectionOpen(entryRecord, art: nil) }
                                   })
            append(railsStack, rail)
            if staggered { railOccur(rail, number: i + tick) }
        }
        // Last on the page: the quiet card, if the package says it is time.
        supportCardAtEnd()
    }

    /// A horizontally paging row. Heading 20 semibold, 10 gap below (`Theme.rail`).
    ///
    /// **No scrollbar but two arrows.** They appear when the pointer is over the row, and only on the side where there is more to see. This is how `Blätterreihe` does it on macOS; the bar GTK shows by itself covered the titles.
    ///
    /// The arrows sit at half **image height**, not half row height: under each image are two text lines, and centred over everything they would sit about 45 points too low. The formula `4 + imageHeight / 2 − 17` is taken literally from macOS: 4 is the row's vertical inset, 17 half the button height.
    /// - Parameter rand: The side inset. **Zero if the caller already sets one**, otherwise the tiles sit 48 points in under a heading that starts at 24. Same as `Blätterreihe` on macOS.
    func railBuild(title: String, art: RailsKind, items: [Item],
                    margin: Int = Theme.edgeSpacing, header: (() -> Void)? = nil) -> Widget! {
        let landscape = art == .continueWatching
        return railBuild(title: title,
                          imageHeight: landscape ? Theme.landscapeHeight : Theme.tileHeight,
                          piece: (landscape ? Theme.landscapeWidth : Theme.tileWidth)
                                  + Theme.tileSpacing,
                          margin: margin, header: header,
                          tiles: items.map { tileBuild($0, art: art) })
    }

    /// **The same row, just not from `Item`.**
    ///
    /// Heading, horizontal paging, the two arrows on hover, the smooth jump by three tiles: none of that depends on anything being a server object. Extracted when the Seerr page needed to show cast and similar; a second version would be the copied function the rules forbid, and the two would have drifted apart.
    func railBuild(title: String, imageHeight: Int, piece: Int,
                    margin: Int = Theme.edgeSpacing, header: (() -> Void)? = nil,
                    tiles: [Widget?]) -> Widget! {
        // 12, not 10: the same role has 12 on the detail page (macOS `Rail`).
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 12)
        // **The row height is fixed, not left to layout** (macOS `Rail.railsHeightValue`): title line 24, 12 gap, 4 inset, image height, 8 gap, text block 32, 4 inset. So "Weiterschauen" has the same space below as every other row, not that of a portrait cover that does not exist there, and a tile without a subline does not make the row shorter. Top-aligned, so nothing hangs in the middle.
        gtk_widget_set_size_request(block, -1, Int32(24 + 12 + 4 + imageHeight + 8 + 32 + 4))
        gtk_widget_set_valign(block, GTK_ALIGN_START)
        gtk_widget_set_vexpand(block, 0)

        let heading = label(title, style: "swiftly-reihe")
        gtk_label_set_xalign(OpaquePointer(heading), 0)
        gtk_widget_set_halign(heading, GTK_ALIGN_START)
        gtk_widget_set_margin_start(heading, Int32(margin))
        gtk_widget_set_margin_end(heading, Int32(margin))
        if let header {
            // **The header is a button if the row has a page** (library row): inset and alignment move to the button.
            gtk_widget_set_margin_start(heading, 0)
            gtk_widget_set_margin_end(heading, 0)
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-reihenkopf")
            gtk_button_set_child(asButton(button), heading)
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_widget_set_margin_start(button, Int32(margin))
            gtk_widget_set_margin_end(button, Int32(margin))
            signal(button, "clicked", header)
            append(block, button)
        } else {
            append(block, heading)
        }

        let scroller = gtk_scrolled_window_new()
        // `EXTERNAL` means: paging yes, bar no.
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: Int32(Theme.tileSpacing))
        gtk_widget_set_margin_start(rail, Int32(margin))
        gtk_widget_set_margin_end(rail, Int32(margin))
        // Four points of space so the growing tile is not clipped at the top; the same four as on macOS.
        gtk_widget_set_margin_top(rail, 4)
        gtk_widget_set_margin_bottom(rail, 4)
        for k in tiles { append(rail, k) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), rail)

        let over = sheetsArea(scroller, imageHeight: imageHeight, piece: piece)

        append(block, over)
        return block
    }

    /// **The paging arrows over a horizontal surface.**
    ///
    /// They used to be built into `railBuild(title:imageHeight:piece:rand:tiles:)` and therefore existed **only** there; the genre chips at the top of the home page were a bare scroller without arrows, the only horizontal row in the app. On macOS `Blätterreihe` builds both (`HomeView.swift:248`).
    private func sheetsArea(_ scroller: Widget!, imageHeight: Int,
                                 piece: Int) -> Widget! {
        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), scroller)

        let left = arrowButton("go-previous-symbolic", top: imageHeight, right: false)
        let right = arrowButton("go-next-symbolic", top: imageHeight, right: true)
        gtk_overlay_add_overlay(OpaquePointer(over), left)
        gtk_overlay_add_overlay(OpaquePointer(over), right)

        // Nobody names the type of this adjustment, it is only passed on. Unwrapped right here: it is never null for a scroller, and the translator asked.
        let adjustment = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroller))!
        var hovers = false

        // **Fade in, do not appear.** On macOS an `.transition(.opacity)` is on the arrows. Here `gtk_widget_set_opacity` was used, which is the opacity of the *widget*, not of the stylesheet: the `transition: opacity` there never applied and the arrows were abruptly there. Now a class toggles the CSS opacity, which fades (`FadeTimes.arrows`, `easeInOut`). `can_target` makes sure an invisible arrow does not swallow a click.
        func showItem(_ button: Widget!, _ yes: Bool) {
            if yes { gtk_widget_add_css_class(button, "swiftly-da") }
            else { gtk_widget_remove_css_class(button, "swiftly-da") }
            gtk_widget_set_can_target(button, yes ? 1 : 0)
        }
        func bringUpToDate() {
            let value = gtk_adjustment_get_value(adjustment)
            let page = gtk_adjustment_get_page_size(adjustment)
            let whole = gtk_adjustment_get_upper(adjustment)
            showItem(left, hovers && value > 1)
            showItem(right, hovers && value + page < whole - 1)
        }

        func turnPages(_ bearing: Double) {
            let value = gtk_adjustment_get_value(adjustment)
            let page = gtk_adjustment_get_page_size(adjustment)
            let whole = gtk_adjustment_get_upper(adjustment)
            // Three tiles per step: `stepRange` on macOS.
            let range = Double(piece) * 3
            let target = max(0, min(whole - page, value + bearing * range))
            gentle(on: scroller, from: value, to: target) {
                gtk_adjustment_set_value(adjustment, $0)
            }
        }

        signal(left, "clicked") { turnPages(-1) }
        signal(right, "clicked") { turnPages(1) }
        // **Not `edge-reached`.** The signal carries the reached edge and thereby shifts the payload; the app crashed because of it. `value-changed` on the adjustment has the plain form and is the right one anyway: it reports every movement, not only at the end, so the arrows are correct mid-scroll.
        signalRaw(UnsafeMutableRawPointer(adjustment), "value-changed") { bringUpToDate() }
        onPointer(over, inward: { hovers = true; bringUpToDate() },
                         out: { hovers = false; bringUpToDate() })
        bringUpToDate()
        return over
    }

    /// A paging arrow, at the top at half image height.
    private func arrowButton(_ symbol: String, top imageHeight: Int, right: Bool) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-pfeil")
        caption(button, right ? translated("Weiterblättern") : translated("Zurückblättern"))
        // **Not a tab stop.** The arrow is invisible until the pointer is over the row; with Tab through the tiles the focus would land on a button the user cannot see. The row scrolls to the focused tile by itself anyway.
        gtk_widget_set_focusable(button, 0)
        gtk_button_set_child(asButton(button), gtk_image_new_from_icon_name(symbol))
        gtk_widget_set_halign(button, right ? GTK_ALIGN_END : GTK_ALIGN_START)
        gtk_widget_set_valign(button, GTK_ALIGN_START)
        gtk_widget_set_margin_top(button, Int32(4 + imageHeight / 2 - 17))
        // Invisible via the stylesheet (`button.swiftly-pfeil`), not via widget opacity, otherwise nothing fades.
        gtk_widget_set_can_target(button, 0)
        return button
    }

    /// **One tile, three meanings.** What is on top, what below, and which image: the row decides, not the tile.
    ///
    /// The mapping is copied from `Sources/macOS/HomeView.swift`:
    ///
    /// | Row | Image | Title | Second line |
    /// |---|---|---|---|
    /// | Weiterschauen | landscape, 280 × 158 | series | `continueWatchingRow` (else `contextLine`) |
    /// | Nächste Folge | series poster | series | `episodeCode` |
    /// | Zuletzt hinzugefügt | poster | own name | `newArrivalsRow` |
    ///
    /// For an episode the **series name** is on top, not the episode title. It was the other way round at first, which shows "Lilien in der Wüste" under a still where macOS shows "The Mentalist".
    private func tileBuild(_ item: Item, art: RailsKind) -> Widget! {
        let landscape = art == .continueWatching
        let width = landscape ? Theme.landscapeWidth : Theme.tileWidth
        let height = landscape ? Theme.landscapeHeight : Theme.tileHeight

        let (cage, image) = framedImage(width: width, height: height,
                                           style: "swiftly-plakat")
        // **Which image is decided by `ImageSelection`** in the package. For an episode, portrait uses the series poster, landscape the series backdrop with four fallbacks behind it. The reasoning for each step is there, with tests.
        //
        // Below that is one more step from `Sources/Shared/HomeView.swift`: **if the landscape image is missing entirely, the poster steps in**; cropped, but still the cover and not a still frame.
        let up = addresses.flatMap {
            ImageSelection.portrait(item, addresses: $0, maxHeight: Scaling.requestEdge(height))
        }
        let address: URL? = landscape
            ? (addresses.flatMap { ImageSelection.landscape(item, addresses: $0, width: Scaling.requestEdge(width))?.url } ?? up)
            : up
        if let address {
            // Double tile edge, or under the shell exactly the device points, see `Skalierung/imageEdge(_:)`.
            imageLoad(image, url: address, key: ImageKey.of(address),
                      border: Scaling.imageEdge(max(width, height)),
                      fallbackSeries: item.seriesId != nil || item.type == "Series")
        } else {
            characterPut(cage, series: item.seriesId != nil || item.type == "Series")
        }

        let (top, bottom): (String, String?) = switch art {
        // **With the remaining time**: "S2 · F5 · noch 12 Min.", for a movie "noch 1 Std. 4 Min.", in place of the quiet line; the image stays free. Without a position, the usual line.
        case .continueWatching: (item.seriesName ?? item.name, item.continueWatchingRow ?? item.contextLine)
        case .next:      (item.seriesName ?? item.name, item.episodeCode)
        case .new:           (item.name, item.newArrivalsRow)
        }

        // The progress bar lies **inside** the image shell, at the bottom, as on macOS: on every tile with a watched portion, landscape or portrait, and only if "Fortschritt auf Kacheln" is on (`macOS/MacComponents.swift`, `ImageArea`).
        if selection.progressOnTiles, let share = item.watchedShare {
            barPut(cage, width: width, share: share)
        }
        // **The badge belongs on every portrait tile**: check mark, open episodes or season count. Not on the landscape tile: there the bar is shown, and both together would be the same information twice.
        if !landscape { tileMarkPut(cage, item: item) }
        // **Only "Weiterschauen" jumps straight into playback.** "Nächste Folge" and "Zuletzt hinzugefügt" open the overview; what has not been started is first looked at.
        return tileWrapper(image: cage, width: width, top: top, bottom: bottom,
                            name: tileName(item, top: top, bottom: bottom),
                            menu: TileMenuDetail(
                                item: item, landscape: landscape, image: address, border: Scaling.imageEdge(max(width, height)),
                                continueWatching: art == .continueWatching,
                                overview: landscape ? { [weak self] in self?.openIt(item) } : nil),
                            prefetch: { [weak self] in
                                self?.seriesPrefetch(item)
                                self?.planPrefetchBald(item)
                            }) {
            [weak self] in
            guard let self else { return }
            if landscape { self.launch(item) } else { self.openIt(item) }
        }
    }

    /// **Fetch the series for an episode before anyone clicks.**
    ///
    /// On a desktop the pointer is always on the tile before clicking; macOS uses this (`SeriesCache.prefetch`, reasoning in `Sources/Shared/SeriesCache.swift:100-124`). Linux lacked it, and a click on a Weiterschauen tile was unresponsive for up to two sequential requests.
    ///
    /// **At most one per series, and only once.** `serienspeicher` holds what is already there; `serienlauf` prevents a second hover from starting the same request again.
    private func seriesPrefetch(_ item: Item) {
        guard item.type == "Episode", let series = item.seriesId, let client else { return }
        guard fullCache[series] == nil, !prefetching.contains(series) else { return }
        prefetching.insert(series)
        Task.detached { [self] in
            let fetched = try? await client.item(id: series)
            onMainThread {
                self.prefetching.remove(series)
                if let fetched { self.fullCache[series] = fetched }
            }
        }
    }

    /// A tile in the grid: poster, name, year.
    ///
    /// **It keeps its width.** A `GtkFlowBox` stretches its children across the row; resizing the window made the posters grow to odd sizes, while on the home page they stay at 150. macOS uses a `LazyVGrid` with a **fixed** column width: leftover space goes into the gap, not the tile. Centre alignment gives exactly that.
    private func gridTile(_ item: Item, inquiry: Bool = false,
                              sentry: TileImageGuard? = nil) -> Widget! {
        let (cage, image) = framedImage(width: Theme.tileWidth,
                                           height: Theme.tileHeight,
                                           style: "swiftly-plakat")
        if let address = addresses.flatMap({ ImageSelection.portrait(item, addresses: $0,
                                                              maxHeight: Scaling.requestEdge(Theme.tileHeight)) }) {
            imageLoad(image, url: address, key: ImageKey.of(address),
                      border: Scaling.imageEdge(Theme.tileHeight),
                      fallbackSeries: item.seriesId != nil || item.type == "Series")
            sentry?.record(image, url: address, key: ImageKey.of(address),
                             border: Scaling.imageEdge(Theme.tileHeight))
        } else {
            characterPut(cage, series: item.seriesId != nil || item.type == "Series")
        }
        // **The badge was missing here entirely**: the search grid and every library grid showed no information about whether a title is watched or how many episodes are open.
        tileMarkPut(cage, item: item)
        // Started titles in library, genre and search, as on macOS.
        if selection.progressOnTiles, let share = item.watchedShare {
            barPut(cage, width: Theme.tileWidth, share: share)
        }
        // Every search hit and every tile in the grid leads to the page; none starts playback.
        let bottom: String? = inquiry ? item.hitInfo : item.productionYear.map(String.init)
        let address = addresses.flatMap { ImageSelection.portrait(item, addresses: $0,
                                                           maxHeight: Scaling.requestEdge(Theme.tileHeight)) }
        let tile = tileWrapper(image: cage, width: Theme.tileWidth,
                                  top: item.name, bottom: bottom,
                                  name: tileName(item, top: item.name, bottom: bottom),
                                  menu: TileMenuDetail(item: item, image: address,
                                                           border: Scaling.imageEdge(Theme.tileHeight)),
                                  prefetch: { [weak self] in self?.planPrefetchBald(item) }) {
            [weak self] in self?.openIt(item)
        }
        gtk_widget_set_halign(tile, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(tile, GTK_ALIGN_START)
        return tile
    }

    /// **The shell of every tile, and it is a button.**
    ///
    /// Not for the click, but because GTK keeps the `:hover` state only on controls. On a plain box the enlargement in the stylesheet would never apply.
    ///
    /// The spacing is in `Macbausteine.PosterCell`: **8** between image and text, **1** between title and second line. Both were 8 at first, and the gap below was twice as large as on macOS. One tile: image, title, second line, and the right-click path to the overview.
    ///
    /// **What it is for:** "Weiterschauen" jumps straight into playback. Whoever wants to *look first* has no other way to the page. macOS uses `.contextMenu` (`Macbausteine`), the phone a long press; here the right button.
    ///
    /// `overview` is `nil` where the tile already leads there; a menu with the one entry the click also does is no menu.
    /// - Parameter vorholen: What happens as soon as the pointer reaches the tile, see below.
    func tileWrapper(image: Widget!, width: Int, top: String, bottom: String?,
                      name: String? = nil,
                      menu: TileMenuDetail? = nil,
                      prefetch: (() -> Void)? = nil,
                      pick: @escaping () -> Void) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-kachel")
        gtk_widget_set_valign(button, GTK_ALIGN_START)

        let tile = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_size_request(tile, Int32(width), -1)
        append(tile, image)

        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 1)
        append(text, tileTitle(top, style: "swiftly-kacheltitel"))
        if let bottom, !bottom.isEmpty {
            let second = tileTitle(bottom, style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(second, "dim-label")
            append(text, second)
        }
        append(tile, text)

        gtk_button_set_child(asButton(button), tile)
        // **One name for the whole tile**, otherwise assistive technology reads title and second line as loose pieces and the bar not at all.
        caption(button, name ?? [top, bottom].compactMap { $0 }
                                    .filter { !$0.isEmpty }.joined(separator: ", "))
        signal(button, "clicked", pick)
        if let prefetch {
            // **Prefetch on hover.** On a desktop the pointer is always on the tile before clicking; macOS uses this (`MacComponents.swift:237-241`, reasoning in `SeriesCache.swift:100-124`) and fetches the series for the episode in advance. It was missing here: a click on a Weiterschauen tile had no reaction for up to two sequential requests.
            onPointer(button, inward: prefetch, out: { [weak self] in self?.planRequest = nil })
        }

        // **Right click: the menu with preview** (`TileMenuDetail`, like the iOS long press). Here only "Übersicht öffnen" existed on the landscape tile; it is now inside as "Zur Übersicht".
        if let menu { tileMenuCreate(button, menu) }
        return button
    }

    /// **A label otherwise stretches the tile to its text length.**
    ///
    /// `gtk_label_set_ellipsize` only lowers the *minimum* width; the preferred width stays the full line. In the "Weiterschauen" row a 363-point tile stood next to 150s because it carried the longest title. `max_width_chars` caps the preference too; the tile then depends only on the image and its own `size_request`.
    private func tileTitle(_ text: String, style: String) -> Widget! {
        let l = label(text, style: style)
        gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(l), 1)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        return l
    }

    func headerRowSetUp() { headerRowFill() }
}

/// The key handler. Like any C callback it cannot capture anything; the app comes along as a pointer, as in `WorkItem`.
nonisolated(unsafe) private let keyPressed: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { _, value, _, condition, data in
    guard let data else { return 0 }
    let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
    let ctrl = (condition.rawValue & GDK_CONTROL_MASK.rawValue) != 0
    return app.keyButton(value, ctrl: ctrl) ? 1 : 0
}

/// The window should close. True means: not yet, the app handles it itself. Like `keyPressed`, the app comes along as a pointer.
nonisolated(unsafe) private let closeRequested: @convention(c) (
    UnsafeMutableRawPointer?, gpointer?
) -> gboolean = { _, data in
    guard let data else { return 0 }
    let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
    app.windowStateRemember()
    return app.windowCloseRequested() ? 1 : 0
}

/// How this app introduces itself to the server.
///
/// The ID must stay the same across restarts; Jellyfin uses it for the device list and for handing over playback from another device.
enum Device {
    /// **The version this app reports to the server.**
    ///
    /// On the Apple versions `JellyfinKit.Fassungsnummer` reads it from the bundle. There is none here, so Foundation returns "unbekannt", and that would appear in Jellyfin's device list and in every error report copied from there.
    ///
    /// **Not retyped but taken from `Version`.** The number exists already, with a comment above it saying it may live in exactly two places. A third would start the drift this is meant to prevent.
    static var version: String { "\(Version.number) (\(Version.build))" }

    static let name: String = {
        let computer = ProcessInfo.processInfo.hostName
        return String(format: translated("Swiftly auf %@"), computer)
    }()

    static let identifier: String = {
        let folder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/swiftly")
        let file = folder.appendingPathComponent("geraet.txt")
        if let available = try? String(contentsOf: file, encoding: .utf8),
           !available.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return available.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let new = UUID().uuidString
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? new.write(to: file, atomically: true, encoding: .utf8)
        return new
    }()
}
