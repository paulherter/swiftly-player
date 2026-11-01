import CGtk
import Foundation
import JellyfinKit

// MARK: - Plex sign-in: code, profile, PIN, server

// The counterpart of `Sources/tvOS/TVPlexSignInView.swift` and the run behind it in
// `Sources/Shared/AppModel+Servers.swift` (`PlexRun`). A desktop has a browser, but this
// app has no in-app browser window, so it takes the way of the television: a short code
// that is typed at plex.tv/link, next to a QR code of that page, and a button that opens
// the page in the system browser.
//
// All state lives on the main thread. Every network call goes through `Task.detached`
// and comes back with `onMainThread`; the `run` number drops answers that belong to an
// earlier attempt (the person pressed "Neuen Code holen" or went back).

final class PlexSignInPage: @unchecked Sendable {

    /// The whole page. Add it where the page belongs.
    let display: Widget
    private let body: Widget
    private let header: Widget?
    private let back: () -> Void
    private let finished: (Session) -> Void
    private let service: PlexAccountService

    // The attempt and what it holds.
    private var run = 0
    private var pin: PlexPin?
    private var expires = Date()
    private var handled = false
    private var failures = 0
    private var accountToken: String?
    private var accountUserID = ""
    private var accountName = ""
    private var accountThumb: String?
    private var homeUsers: [PlexHomeUser] = []
    private var profile: PlexHomeUser?
    private var profileToken: String?
    private var servers: [PlexServerResource] = []
    private var connecting: String?
    private var unreachable: Set<String> = []
    private var pinWrong = false
    private var pinChecking = false

    /// The countdown line while the code is shown; reset when its widget goes.
    private var countdown: Widget?
    private var pinField: Widget?
    private var isWaiting = false

    /// - Parameters:
    ///   - header: the subpage header with its arrow; `nil` on the first start, where the
    ///     page draws its own title and a "Zurück" under each step.
    ///   - back: leaves the page (to the picker).
    ///   - finished: the account is in. The caller stores it and leaves.
    init(header: Widget?, back: @escaping () -> Void,
         finished: @escaping (Session) -> Void) {
        self.header = header
        self.back = back
        self.finished = finished
        self.service = PlexAccountService(
            identity: .thisDevice(clientID: Device.identifier, deviceName: Device.name))

        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(column, Int32(Theme.formWidth), -1)
        gtk_widget_set_halign(column, GTK_ALIGN_START)
        display = column!

        if let header {
            append(column, header)
        } else {
            let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
            let mark = KindMark(kind: .plex, size: 30)
            append(rail, mark.display)
            let title = label(ServerKind.plex.shownName, style: "swiftly-titel-gross")
            gtk_widget_set_valign(title, GTK_ALIGN_CENTER)
            append(rail, title)
            append(column, rail)
        }
        body = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_top(body, 24)
        append(column, body)
        showIntro()
    }

    /// Back to the first step with a fresh state. Called when the page is shown again.
    func reset() {
        stop()
        pin = nil
        accountToken = nil
        profileToken = nil
        profile = nil
        homeUsers = []
        servers = []
        unreachable = []
        connecting = nil
        showIntro()
    }

    /// Ends polling. Answers still on their way are dropped by the changed `run`.
    func stop() {
        run += 1
        isWaiting = false
    }

    // MARK: Building blocks

    private func clear() {
        countdown = nil
        pinField = nil
        isWaiting = false
        wipe(body)
    }

    private func sentence(_ text: String, quiet: Bool = true) -> Widget! {
        let l = label(text, style: "swiftly-koerper", wrap: true)
        if quiet { gtk_widget_add_css_class(l, "dim-label") }
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(l, 10)
        return l
    }

    private func heading(_ text: String) -> Widget! {
        let l = label(text, style: "swiftly-kontoname")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_margin_bottom(l, 12)
        return l
    }

    private func quietButton(_ text: String, top: Int32 = 16, _ action: @escaping () -> Void) -> Widget! {
        let b = gtk_button_new_with_label(text)
        gtk_widget_add_css_class(b, "swiftly-flach")
        gtk_widget_set_halign(b, GTK_ALIGN_START)
        gtk_widget_set_margin_top(b, top)
        signal(b, "clicked") { action() }
        return b
    }

    /// "Zurück" under a step, only where there is no header arrow.
    private func backButton() -> Widget? {
        header == nil ? quietButton(translated("Zurück")) { [self] in stop(); back() } : nil
    }

    private func mainButton(_ text: String, symbol: String = "go-next-symbolic",
                            _ action: @escaping () -> Void) -> Widget! {
        let b = primaryButton(text, symbol: symbol)
        gtk_widget_set_halign(b, GTK_ALIGN_START)
        gtk_widget_set_margin_top(b, 24)
        signal(b, "clicked") { action() }
        return b
    }

    // MARK: Step: intro

    private func showIntro() {
        clear()
        append(body, sentence(translated("Die Anmeldung läuft auf der Seite von Plex. Dein Passwort bekommt Swiftly Player nie zu sehen.")))
        append(body, sentence(translated("Gleich bekommst du einen Code. Den gibst du am Handy oder Computer auf plex.tv/link ein.")))
        append(body, mainButton(translated("Mit Plex anmelden")) { [self] in start() })
        if let b = backButton() { append(body, b) }
    }

    private func showOpening() {
        clear()
        append(body, sentence(translated("Wird geöffnet …")))
    }

    func start() {
        stop()
        let mine = run
        handled = false
        failures = 0
        showOpening()
        let service = service
        Task.detached { [self] in
            do {
                let pin = try await service.startPin(strong: false)
                onMainThread { self.begin(pin, mine) }
            } catch {
                let problem = error
                onMainThread { self.fail(problem, mine) }
            }
        }
    }

    private func begin(_ pin: PlexPin, _ mine: Int) {
        guard mine == run else { return }
        self.pin = pin
        expires = Date().addingTimeInterval(TimeInterval(pin.expiresIn ?? 900))
        showWaiting(pin)
        isWaiting = true
        pollStep(mine)
    }

    // MARK: Step: waiting for the code

    private func showWaiting(_ pin: PlexPin) {
        clear()
        let link = service.linkPage
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 22)
        gtk_widget_set_valign(rail, GTK_ALIGN_START)

        if let modules = QRCode.modules(for: link.absoluteString) {
            let size = 150
            let quiet = 2
            let count = modules.count
            let cell = max(size / (count + 2 * quiet), 1)
            let side = cell * (count + 2 * quiet)
            let qr = paint(width: side, height: side) { _, cr, _, _ in
                cairo_set_source_rgb(cr, 1, 1, 1)
                LookArt.rounded(cr, 0, 0, Double(side), Double(side), 8)
                cairo_fill(cr)
                cairo_set_source_rgb(cr, 0, 0, 0)
                for (y, line) in modules.enumerated() {
                    for (x, dark) in line.enumerated() where dark {
                        cairo_rectangle(cr, Double((x + quiet) * cell), Double((y + quiet) * cell),
                                        Double(cell), Double(cell))
                    }
                }
                cairo_fill(cr)
            }
            gtk_widget_set_valign(qr, GTK_ALIGN_START)
            append(rail, qr)
        }

        let texts = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(texts, 1)
        let ask = sentence(String(format: translated("Geh auf %@ und gib diesen Code ein."), "plex.tv/link"),
                           quiet: false)
        gtk_widget_set_margin_top(ask, 0)
        append(texts, ask)
        let code = label(pin.code, style: "swiftly-codegross")
        gtk_label_set_selectable(OpaquePointer(code), 1)
        gtk_widget_set_halign(code, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(code, 1)
        gtk_widget_set_margin_top(code, 14)
        append(texts, code)
        let left = label("", style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(left, "swiftly-sehrleise")
        gtk_label_set_xalign(OpaquePointer(left), 0)
        gtk_widget_set_margin_top(left, 12)
        append(texts, left)
        countdown = left
        signal(left, "destroy") { [self] in if countdown == left { countdown = nil } }
        append(rail, texts)
        append(body, rail)
        countdownRefresh()

        let open = mainButton(translated("Seite noch mal öffnen"), symbol: "go-next-symbolic") {
            [self] in browser(service.linkPage)
        }
        append(body, open)
        let fresh = quietButton(translated("Neuen Code holen")) { [self] in start() }
        append(body, fresh)
        if let b = backButton() { append(body, b) }
    }

    private func countdownRefresh() {
        guard let countdown else { return }
        let seconds = max(Int(expires.timeIntervalSinceNow.rounded(.up)), 0)
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        gtk_label_set_text(OpaquePointer(countdown),
                           String(format: translated("Warte auf Plex · noch %@"), time))
    }

    // MARK: Polling: about once a second until the token is there or the code is gone

    private enum Poll: Sendable { case token(String), waiting, failed(any Error) }

    private func pollStep(_ mine: Int) {
        guard mine == run, isWaiting, !handled, let pin else { return }
        if Date() >= expires { fail(PlexError.pinExpired, mine); return }
        countdownRefresh()
        let service = service
        Task.detached { [self] in
            let result: Poll
            do {
                if let token = try await service.checkPin(pin).authToken, !token.isEmpty {
                    result = .token(token)
                } else {
                    result = .waiting
                }
            } catch JellyfinError.http(let status, _) where status == 404 || status == 410 {
                result = .failed(PlexError.pinExpired)
            } catch {
                result = .failed(error)
            }
            onMainThread {
                guard mine == self.run, self.isWaiting, !self.handled else { return }
                switch result {
                case .token(let token):
                    self.signedIn(token: token, mine)
                    return
                case .waiting:
                    self.failures = 0
                case .failed(let error):
                    if let plex = error as? PlexError, plex == .pinExpired {
                        self.fail(error, mine)
                        return
                    }
                    self.failures += 1
                    if self.failures >= 5 { self.fail(error, mine); return }
                }
                postDeadline(1.0) { self.pollStep(mine) }
            }
        }
    }

    // MARK: After the token

    private func showLoading() {
        clear()
        append(body, sentence(translated("Lädt gerade")))
    }

    private func signedIn(token: String, _ mine: Int) {
        guard !handled else { return }
        handled = true
        isWaiting = false
        showLoading()
        let service = service
        Task.detached { [self] in
            do {
                guard case .valid(let account) = try await service.validate(token: token) else {
                    throw PlexError.pinExpired
                }
                let users = (try? await service.homeUsers(token: token)) ?? []
                onMainThread {
                    guard mine == self.run else { return }
                    self.accountToken = token
                    self.accountUserID = account.id
                    self.accountName = account.title
                    self.accountThumb = account.thumb
                    self.homeUsers = users
                    if users.count > 1 {
                        self.showProfiles()
                    } else {
                        self.profile = users.first
                        self.profileToken = token
                        self.loadServers()
                    }
                }
            } catch {
                let problem = error
                onMainThread { self.fail(problem, mine) }
            }
        }
    }

    // MARK: Step: who is watching

    private func showProfiles() {
        clear()
        append(body, heading(translated("Wer schaut?")))

        let flow: Widget! = gtk_flow_box_new()
        gtk_flow_box_set_selection_mode(OpaquePointer(flow), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(OpaquePointer(flow), 1)
        gtk_flow_box_set_max_children_per_line(OpaquePointer(flow), 4)
        gtk_flow_box_set_column_spacing(OpaquePointer(flow), 10)
        gtk_flow_box_set_row_spacing(OpaquePointer(flow), 10)
        for user in homeUsers {
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-flach")
            let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
            gtk_widget_set_halign(column, GTK_ALIGN_CENTER)

            let parts = profileCharacter(name: user.title, border: 84, style: "swiftly-profilgross",
                                         fontStyle: "swiftly-zeichen84")
            profileImageLoad(parts, url: user.thumb.flatMap(URL.init(string:)),
                             key: "plex-\(user.uuid)")
            if user.isProtected {
                let lock = paint(width: 18, height: 18) { widget, cr, _, _ in
                    let c = LookArt.color(of: widget)
                    cairo_set_source_rgba(cr, c.0, c.1, c.2, c.3)
                    LookArt.rounded(cr, 3, 8, 12, 9, 2)
                    cairo_fill(cr)
                    cairo_set_line_width(cr, 1.8)
                    cairo_arc(cr, 9, 8, 3.2, Double.pi, 2 * Double.pi)
                    cairo_stroke(cr)
                }
                gtk_widget_add_css_class(lock, "swiftly-leise")
                gtk_widget_set_halign(lock, GTK_ALIGN_END)
                gtk_widget_set_valign(lock, GTK_ALIGN_START)
                gtk_overlay_add_overlay(OpaquePointer(parts.wrapper), lock)
            }
            append(column, parts.wrapper)

            let name = label(user.title, style: "swiftly-zweitzeile")
            gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(OpaquePointer(name), 12)
            append(column, name)

            gtk_button_set_child(asButton(button), column)
            caption(button, user.isProtected
                    ? "\(user.title), \(translated("Mit PIN"))" : user.title)
            signal(button, "clicked") { [self] in pickProfile(user) }
            gtk_flow_box_append(OpaquePointer(flow), button)
        }
        append(body, flow)

        let footer = sentence(translated("Jedes Profil hat seinen eigenen Fortschritt."))
        gtk_widget_add_css_class(footer, "swiftly-sehrleise")
        gtk_widget_set_margin_top(footer, 18)
        append(body, footer)
        append(body, quietButton(translated("Anderes Plex-Konto")) { [self] in otherAccount() })
    }

    private func pickProfile(_ user: PlexHomeUser) {
        if user.isProtected {
            pinWrong = false
            pinChecking = false
            showPin(user)
        } else {
            switchTo(user, pin: nil)
        }
    }

    // MARK: Step: PIN

    private func showPin(_ user: PlexHomeUser) {
        clear()
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        let parts = profileCharacter(name: user.title, border: 56, style: "swiftly-profilgross",
                                     fontStyle: "swiftly-zeichen72")
        profileImageLoad(parts, url: user.thumb.flatMap(URL.init(string:)), key: "plex-\(user.uuid)")
        append(rail, parts.wrapper)
        let name = label(user.title, style: "swiftly-kontoname")
        gtk_widget_set_valign(name, GTK_ALIGN_CENTER)
        append(rail, name)
        append(body, rail)
        append(body, sentence(translated("Dieses Profil hat eine PIN. Gib sie hier ein.")))

        let field = inputRow(symbol: "dialog-password-symbolic", placeholder: translated("PIN"),
                             secret: true, stretches: true)
        gtk_entry_set_max_length(asField(field), 4)
        gtk_widget_set_margin_top(field, 18)
        append(body, field)
        pinField = field
        signal(field, "destroy") { [self] in if pinField == field { pinField = nil } }

        let state = label("", style: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(state), 0)
        gtk_widget_set_margin_top(state, 10)
        append(body, state)
        pinStateShow(state)

        signal(field, "changed") { [self] in
            guard !pinChecking, let current = pinField else { return }
            let typed = String(cString: gtk_editable_get_text(OpaquePointer(current)))
            let digits = String(typed.filter(\.isNumber).prefix(4))
            if digits != typed {
                gtk_editable_set_text(OpaquePointer(current), digits)
                return
            }
            if !digits.isEmpty, pinWrong { pinWrong = false; pinStateShow(state) }
            guard digits.count == 4 else { return }
            pinChecking = true
            pinStateShow(state)
            switchTo(user, pin: digits)
        }
        append(body, quietButton(translated("Zurück zu den Profilen")) { [self] in showProfiles() })
        gtk_widget_grab_focus(field)
    }

    private func pinStateShow(_ state: Widget!) {
        if pinChecking {
            gtk_label_set_text(OpaquePointer(state), translated("Wird geprüft …"))
            gtk_widget_remove_css_class(state, "swiftly-warnung")
        } else if pinWrong {
            gtk_label_set_text(OpaquePointer(state), translated("Die PIN passt nicht. Versuchs noch mal."))
            gtk_widget_add_css_class(state, "swiftly-warnung")
        } else {
            gtk_label_set_text(OpaquePointer(state), "")
        }
    }

    private func switchTo(_ user: PlexHomeUser, pin: String?) {
        guard let account = accountToken else { return }
        let mine = run
        let service = service
        Task.detached { [self] in
            do {
                let token = try await service.switchUser(user, pin: pin, token: account)
                onMainThread {
                    guard mine == self.run else { return }
                    self.pinChecking = false
                    self.profile = user
                    self.profileToken = token
                    self.loadServers()
                }
            } catch PlexError.profilePinWrong {
                onMainThread {
                    guard mine == self.run else { return }
                    self.pinChecking = false
                    if pin != nil {
                        // Stay on the PIN page with an empty field.
                        self.pinWrong = true
                        self.showPin(user)
                    } else {
                        self.fail(PlexError.profilePinWrong, mine)
                    }
                }
            } catch {
                let problem = error
                onMainThread { self.pinChecking = false; self.fail(problem, mine) }
            }
        }
    }

    // MARK: Step: servers

    private func loadServers() {
        guard let token = profileToken ?? accountToken else { return }
        let mine = run
        showLoading()
        unreachable = []
        let service = service
        Task.detached { [self] in
            do {
                let found = try await service.servers(token: token)
                onMainThread {
                    guard mine == self.run else { return }
                    self.servers = found
                    self.showServers()
                }
            } catch {
                let problem = error
                onMainThread { self.fail(problem, mine) }
            }
        }
    }

    private func showServers() {
        guard !servers.isEmpty else { showNoServer(); return }
        clear()
        append(body, heading(translated("Deine Server")))

        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        for server in servers {
            let busy = connecting == server.machineIdentifier
            let failed = unreachable.contains(server.machineIdentifier)
            let card = rowsGroup()
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-einstellzeile")
            let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
            gtk_widget_set_margin_start(row, 16)
            gtk_widget_set_margin_end(row, 16)
            gtk_widget_set_margin_top(row, 12)
            gtk_widget_set_margin_bottom(row, 12)

            let icon: Widget! = gtk_image_new_from_icon_name("drive-harddisk-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(icon), 20)
            gtk_widget_add_css_class(icon, "swiftly-leise")
            gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
            append(row, icon)

            let texts = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
            gtk_widget_set_hexpand(texts, 1)
            gtk_widget_set_valign(texts, GTK_ALIGN_CENTER)
            let name = label(server.name, style: "swiftly-kontoname")
            gtk_label_set_xalign(OpaquePointer(name), 0)
            gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
            append(texts, name)
            let line = label(serverLine(server, busy: busy, failed: failed), style: "swiftly-zweitzeile")
            gtk_label_set_xalign(OpaquePointer(line), 0)
            gtk_label_set_ellipsize(OpaquePointer(line), PANGO_ELLIPSIZE_END)
            if failed {
                gtk_widget_add_css_class(line, "swiftly-warnung")
            } else if !busy {
                gtk_widget_add_css_class(line, "swiftly-leise")
            }
            append(texts, line)
            append(row, texts)

            if !busy {
                let chevron: Widget! = gtk_image_new_from_icon_name("go-next-symbolic")
                gtk_image_set_pixel_size(OpaquePointer(chevron), 13)
                gtk_widget_add_css_class(chevron, "swiftly-sehrleise")
                gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
                append(row, chevron)
            }
            gtk_button_set_child(asButton(button), row)
            caption(button, server.name)
            gtk_widget_set_sensitive(button, connecting == nil || busy ? 1 : 0)
            signal(button, "clicked") { [self] in pickServer(server) }
            append(card.space, button)
            append(list, card.outer)
        }
        append(body, list)

        if let profile {
            let as_ = sentence(String(format: translated("Als %@"), profile.title))
            gtk_widget_add_css_class(as_, "swiftly-sehrleise")
            gtk_widget_set_margin_top(as_, 14)
            append(body, as_)
        }
        let other = quietButton(translated("Anderes Plex-Konto"), top: 8) { [self] in
            if connecting == nil { otherAccount() }
        }
        append(body, other)
    }

    private func serverLine(_ server: PlexServerResource, busy: Bool, failed: Bool) -> String {
        if busy { return translated("Verbinden …") }
        if failed { return translated("Antwortet gerade nicht. Klick für einen neuen Versuch.") }
        let owner = server.owned
            ? translated("Dein Server")
            : String(format: translated("Von %@ freigegeben"),
                     server.sourceTitle ?? translated("einem anderen Konto"))
        let place = !server.presence ? translated("laut Plex offline")
            : server.connections.contains { $0.isLocal } ? translated("im WLAN")
            : translated("über das Internet")
        return "\(owner) · \(place)"
    }

    private func pickServer(_ server: PlexServerResource) {
        guard connecting == nil, let accountToken else { return }
        let mine = run
        let profileToken = profileToken ?? accountToken
        connecting = server.machineIdentifier
        unreachable.remove(server.machineIdentifier)
        showServers()
        // The server's own token opens it; the profile's token asks plex.tv.
        let connector = PlexConnector(identity: service.identity,
                                      token: server.accessToken ?? profileToken,
                                      machineIdentifier: server.machineIdentifier)
        let user = profile
        let accountUserID = accountUserID, accountName = accountName, accountThumb = accountThumb
        Task.detached { [self] in
            do {
                let connection = try await Self.connect(connector, to: server)
                let session = Session(plexServer: server, connection: connection,
                                      accountToken: profileToken,
                                      userID: user?.id ?? accountUserID,
                                      userName: user?.title ?? accountName,
                                      homeUserUUID: user?.uuid,
                                      userImage: (user?.thumb ?? accountThumb).flatMap(URL.init(string:)))
                onMainThread {
                    guard mine == self.run else { return }
                    self.connecting = nil
                    self.finished(session)
                }
            } catch {
                onMainThread {
                    guard mine == self.run else { return }
                    self.connecting = nil
                    self.unreachable.insert(server.machineIdentifier)
                    self.showServers()
                }
            }
        }
    }

    /// One try; when it failed at once, a second one after a moment. A server that is really
    /// gone fails slowly and is not asked twice.
    private static func connect(_ connector: PlexConnector,
                                to server: PlexServerResource) async throws -> PlexChosenConnection {
        let started = ContinuousClock.now
        do {
            return try await connector.choose(from: server)
        } catch {
            guard ContinuousClock.now - started < .seconds(2) else { throw error }
            try await Task.sleep(for: .seconds(1.5))
            return try await connector.choose(from: server)
        }
    }

    private func otherAccount() {
        stop()
        pin = nil
        accountToken = nil
        profileToken = nil
        profile = nil
        homeUsers = []
        servers = []
        connecting = nil
        showIntro()
    }

    // MARK: Empty and failed states

    private func notice(symbol: String, title: String, text: String,
                        primary: (String, () -> Void), secondary: (String, () -> Void)? = nil) {
        clear()
        let icon: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(icon), 32)
        gtk_widget_add_css_class(icon, "swiftly-sehrleise")
        gtk_widget_set_halign(icon, GTK_ALIGN_START)
        append(body, icon)
        let t = label(title, style: "swiftly-kontoname")
        gtk_label_set_xalign(OpaquePointer(t), 0)
        gtk_widget_set_margin_top(t, 12)
        append(body, t)
        append(body, sentence(text))
        append(body, mainButton(primary.0, symbol: "view-refresh-symbolic", primary.1))
        if let secondary {
            append(body, quietButton(secondary.0, secondary.1))
        } else if let b = backButton() {
            append(body, b)
        }
    }

    private func showNoServer() {
        notice(symbol: "network-server-symbolic",
               title: translated("Kein Server auf diesem Konto"),
               text: translated("Richte Plex Media Server ein oder lass dir einen freigeben. Danach hier noch mal suchen."),
               primary: (translated("Noch mal suchen"), { [self] in loadServers() }),
               secondary: (translated("Anderes Plex-Konto"), { [self] in otherAccount() }))
    }

    private func fail(_ error: any Error, _ mine: Int) {
        guard mine == run else { return }
        stop()
        let again: () -> Void = { [self] in start() }
        if let plex = error as? PlexError {
            switch plex {
            case .pinExpired:
                notice(symbol: "appointment-missed-symbolic",
                       title: translated("Die Anmeldung ist abgelaufen"),
                       text: translated("Der Code war zu lange offen. Hol dir einfach einen neuen."),
                       primary: (translated("Neuen Code holen"), again))
            case .noServer:
                servers = []
                showNoServer()
            default:
                other(readableError(error), again)
            }
            return
        }
        if error is URLError {
            unreachableShow(again)
        } else if let j = error as? JellyfinError, case .transport = j {
            unreachableShow(again)
        } else {
            other(readableError(error), again)
        }
    }

    private func unreachableShow(_ again: @escaping () -> Void) {
        notice(symbol: "network-offline-symbolic",
               title: translated("plex.tv antwortet nicht"),
               text: translated("Ohne plex.tv klappt die Anmeldung nicht. Hängt vielleicht das WLAN?"),
               primary: (translated("Erneut versuchen"), again))
    }

    private func other(_ message: String, _ again: @escaping () -> Void) {
        notice(symbol: "dialog-warning-symbolic",
               title: translated("Anmeldung hat nicht geklappt"),
               text: message,
               primary: (translated("Erneut versuchen"), again))
    }
}
