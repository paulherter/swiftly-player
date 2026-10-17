import CGtk
import Foundation
import JellyfinKit

/// **Trakt on Linux and Windows**: the same integration as on Apple
/// (`Sources/Shared/TraktAccount.swift`), with the same logic from the package
/// (`TraktClient`, `TraktReporter`). This file only has storage, the page and
/// the calls from the player.
///
/// **Without `Trakt.json` in the build none of it exists**: no row in
/// settings, no reporter. The file is not in the repo; see `TraktAccess` in
/// the package.
final class TraktStatus: @unchecked Sendable {
    let client: TraktClient? = TraktAccess.outPackage.map { TraktClient(access: $0) }

    /// One credential set per Jellyfin account, as on Apple: what the children
    /// watch does not belong in the parents' history. Main thread only.
    var tokens: [String: TraktToken] = TraktStatus.read()

    /// The state of the sign-in page. Main thread only.
    var code: TraktDevicesCode?
    var codeUntil = Date.distantPast
    var error: String?
    var fetches = false
    var preGait: Task<Void, Never>?
    /// "Läuft ab in 9:58" (expires in): forgets itself when GTK tears it down.
    var remainingField: Widget?

    lazy var reporter: TraktReporter? = client.map { client in
        TraktReporter(
            client: client,
            changed: { new, identifier in
                guard let identifier else { return }
                onMainThread { traktStatus.remember(new, account: identifier) }
            },
            log: { row in AppLog.writeOut("[Trakt] " + row) })
    }

    var available: Bool { client != nil }

    func remember(_ new: TraktToken?, account: String) {
        tokens[account] = new
        TraktStatus.write(tokens)
    }

    // MARK: Storage

    /// **Next to the session, with the same permissions** (file mode 0600), the
    /// same trade-off as for the Seerr credentials in `Cache.swift`: a keyring
    /// would cost a new dependency here.
    private static var file: URL {
        Platform.settingFolder.appendingPathComponent("trakt.json")
    }

    private static func read() -> [String: TraktToken] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: TraktToken].self, from: data)) ?? [:]
    }

    private static func write(_ tokens: [String: TraktToken]) {
        guard !tokens.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try FileManager.default.createDirectory(at: Platform.settingFolder,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(tokens).write(to: file, options: [.atomic])
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: file.path)
            #endif
        } catch {
            AppLog.writeOut("[Trakt] Zugang ließ sich nicht sichern: \(error.localizedDescription)")
        }
    }
}

let traktStatus = TraktStatus()

extension App {

    private var traktAccount: String? { bundle?.activeOne.accountKey }
    private var traktToken: TraktToken? { traktAccount.flatMap { traktStatus.tokens[$0] } }

    // MARK: Playback, alongside the reports to Jellyfin

    /// The token is passed through the queue before every start, so after an
    /// account switch the right one applies immediately, with no special hook in
    /// the switch.
    func traktStart(_ client: JellyfinClient, title: Item, ticks: Int64) {
        guard let reporter = traktStatus.reporter else { return }
        let token = traktToken
        reporter.tokenSet(token, identifier: traktAccount)
        guard token != nil else { return }
        reporter.report(.start(titleID: title.id,
                             target: { await TraktTarget.resolve(title, client: client) },
                             spot: Double(ticks) / 10_000_000,
                             duration: title.runtimeSeconds ?? 0))
    }

    func traktRunState(running: Bool, spot: Double) {
        traktStatus.reporter?.report(.runState(running: running, spot: spot))
    }

    func traktJump(on spot: Double) {
        traktStatus.reporter?.report(.leap(spot: spot))
    }

    func traktStop(title: Item, ticks: Int64) {
        traktStatus.reporter?.report(.stop(titleID: title.id, spot: Double(ticks) / 10_000_000))
    }

    // MARK: Settings

    /// The row under Seerr, only with credentials in the build.
    func traktRow(_ space: Widget!) {
        guard traktStatus.available else { return }
        let present = traktToken != nil
        append(space, rowsLine())
        append(space, valuesRow(symbol: "object-select-symbolic",
                                   title: "Trakt",
                                   under: translated("Trägt ein, was du schaust"),
                                   value: present ? translated("Verbunden") : nil,
                                   arrow: !present) { [weak self] in
            self?.subpageOpen(.trakt)
        })
    }

    /// The page, built like the Mac one
    /// (`Sources/macOS/TraktSettingsView.swift`): header, explanation, then
    /// "Verbunden" or the way there, and below it the pointer to the plugin.
    func traktPageBuild(_ block: Widget!) {
        let header = subpageHeader("Trakt")
        gtk_widget_set_margin_bottom(header, 10)
        append(block, header)
        // **Leaving the page cancels polling**, otherwise the app would keep asking
        // for ten minutes. When the same page is rebuilt the header is also removed;
        // it is then open again afterwards.
        signal(header, "destroy") {
            onMainThread { if app.openSubpage != .trakt { app.traktCancel() } }
        }

        let text = label(
            translated("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen."),
            style: "swiftly-koerper", wrap: true)
        gtk_widget_add_css_class(text, "dim-label")
        gtk_label_set_xalign(OpaquePointer(text), 0)
        append(block, text)

        if let token = traktToken {
            let g = settingGroup(translated("Verbunden"))
            gtk_widget_set_margin_top(g.outer, 26)
            append(g.space, valuesRow(symbol: "network-transmit-receive-symbolic",
                                         title: token.user ?? "Trakt",
                                         value: translated("Aktiv")))
            append(g.space, rowsLine())
            // "Trennen", not "Abmelden", as with Seerr.
            append(g.space, valuesRow(symbol: "window-close-symbolic",
                                         title: translated("Verbindung trennen")) { [weak self] in
                self?.traktDisconnect()
            })
            append(block, g.outer)
        } else {
            traktLoginPart(block)
        }

        let hint = label(
            translated("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt."),
            style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(hint, "swiftly-sehrleise")
        gtk_label_set_xalign(OpaquePointer(hint), 0)
        gtk_widget_set_margin_top(hint, 14)
        append(block, hint)
    }

    private func traktLoginPart(_ block: Widget!) {
        let part = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_top(part, 26)
        append(block, part)

        if let code = traktStatus.code {
            let sentence = label(String(format: translated("Geh auf %@ und gib diesen Code ein."),
                                           code.addressShort),
                                    style: "swiftly-koerper", wrap: true)
            gtk_label_set_xalign(OpaquePointer(sentence), 0)
            append(part, sentence)

            let inputField = label(code.userCode, style: "swiftly-codegross")
            gtk_label_set_selectable(OpaquePointer(inputField), 1)
            gtk_widget_set_halign(inputField, GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(inputField, 1)
            gtk_widget_set_margin_top(inputField, 16)
            append(part, inputField)

            let rest = label("", style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(rest, "swiftly-sehrleise")
            gtk_label_set_xalign(OpaquePointer(rest), 0)
            gtk_widget_set_margin_top(rest, 10)
            append(part, rest)
            traktStatus.remainingField = rest
            // Only forget if it is still this field; on a rebuild the next one may
            // already be in place.
            let container = PointerBox(rest)
            signal(rest, "destroy") {
                if traktStatus.remainingField == container.widget { traktStatus.remainingField = nil }
            }
            traktRemainingShow()

            // With the code in the URL, so nothing has to be typed.
            let open = primaryButton(translated("Trakt öffnen"), symbol: "go-next-symbolic")
            gtk_widget_set_margin_top(open, 20)
            let target = code.directAddress
            signal(open, "clicked") { browser(target) }
            append(part, open)
            return
        }

        if traktStatus.fetches {
            let l = label(translated("Hole Code…"), style: "swiftly-koerper")
            gtk_widget_add_css_class(l, "dim-label")
            gtk_label_set_xalign(OpaquePointer(l), 0)
            append(part, l)
            return
        }

        if let error = traktStatus.error {
            let l = label(error, style: "swiftly-zweitzeile", wrap: true)
            gtk_widget_add_css_class(l, "swiftly-warnung")
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_widget_set_margin_bottom(l, 20)
            append(part, l)
        }
        let button = primaryButton(traktStatus.error == nil ? translated("Mit Trakt verbinden")
                                                       : translated("Neuer Code"),
                               symbol: "object-select-symbolic")
        signal(button, "clicked") { [weak self] in self?.traktConnect() }
        append(part, button)
    }

    private func traktRemainingShow() {
        guard let inputField = traktStatus.remainingField else { return }
        let seconds = max(0, Int(traktStatus.codeUntil.timeIntervalSinceNow))
        let text = String(format: translated("Läuft ab in %lld:%@"),
                          seconds / 60, String(format: "%02d", seconds % 60))
        gtk_label_set_text(OpaquePointer(inputField), text)
    }

    /// Only rebuild if the page is still open; someone who clicked on should not
    /// be pulled back.
    private func traktPageRefresh() {
        guard openSubpage == .trakt else { return }
        subpageOpen(.trakt, push: .without)
    }

    private func traktConnect() {
        guard let client = traktStatus.client, let account = traktAccount else { return }
        traktStatus.preGait?.cancel()
        traktStatus.code = nil
        traktStatus.error = nil
        traktStatus.fetches = true
        traktPageRefresh()
        traktStatus.preGait = Task.detached { [self] in
            do {
                let code = try await client.devicesCode()
                onMainThread {
                    traktStatus.fetches = false
                    traktStatus.code = code
                    traktStatus.codeUntil = Date().addingTimeInterval(code.valid)
                    self.traktPageRefresh()
                }
                // The one-second tick for "Läuft ab in"; it ends with the operation.
                let tick = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        onMainThread { self.traktRemainingShow() }
                    }
                }
                defer { tick.cancel() }
                var new = try await client.sharingWaitFor(code)
                new.user = await client.username(new)
                let done = new
                guard !Task.isCancelled else { return }
                onMainThread {
                    traktStatus.remember(done, account: account)
                    traktStatus.code = nil
                    if self.traktAccount == account {
                        traktStatus.reporter?.tokenSet(done, identifier: account)
                    }
                    self.traktPageRefresh()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let text = Self.traktText(error)
                onMainThread {
                    traktStatus.fetches = false
                    traktStatus.code = nil
                    traktStatus.error = text
                    self.traktPageRefresh()
                }
            }
        }
    }

    /// On leaving the page: do not keep asking for ten minutes.
    func traktCancel() {
        traktStatus.preGait?.cancel()
        traktStatus.preGait = nil
        traktStatus.code = nil
        traktStatus.fetches = false
        traktStatus.error = nil
    }

    private func traktDisconnect() {
        guard let account = traktAccount else { return }
        let alt = traktStatus.tokens[account]
        traktStatus.remember(nil, account: account)
        traktStatus.reporter?.tokenSet(nil, identifier: account)
        if let alt, let client = traktStatus.client {
            Task.detached { await client.revoked(alt) }
        }
        traktPageRefresh()
    }

    private static func traktText(_ error: any Error) -> String {
        switch error as? TraktError {
        case .codeExpired: translated("Der Code ist abgelaufen. Hol dir einen neuen.")
        case .rejected:      translated("Trakt hat die Verbindung nicht freigegeben.")
        case .rateLimit:     translated("Trakt bremst gerade. Versuch es in ein paar Minuten noch mal.")
        default:              translated("Trakt ist gerade nicht erreichbar.")
        }
    }
}
