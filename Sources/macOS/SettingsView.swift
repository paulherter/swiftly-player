import JellyfinKit
import SwiftUI

/// App settings.
///
/// Holds what concerns the app. Everything about playback lives on a page of its
/// own, otherwise the same thing would appear in two places. This split matches
/// the iPhone version and stays the same on all platforms.
struct SettingsView: View {
    let model: AppModel
    let back: () -> Void
    @State private var headerState = HeaderState()

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    @State private var verification: String?
    @State private var examine = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MacPageTitle(text: "Allgemein", bottom: 0)

                // Two columns of 470, gap 24 (design). Left: offline, then Swiftly. Right: server
                // and services, then sync. Rows only the connected kind can use are not shown.
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        offline
                        MacSupportSettingsGroup()
                            .padding(.top, 6)
                    }
                    .frame(minWidth: 0, maxWidth: 470, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 0) {
                        server
                        // Settings follow the account to every device (`SettingsSyncRun`).
                        // Only servers that keep display preferences (`ServerCapability.settingsSync`).
                        if model.can(.settingsSync) {
                            SettingGroup(title: "Synchronisierung", topGap: 28) {
                                switchRow("einstellungenSync", "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                    .frame(minWidth: 0, maxWidth: 470, alignment: .topLeading)
                }
                .frame(maxWidth: 964, alignment: .leading)

                // The version is a minor detail: 12 pt in `schriftSehrLeise`.
                HStack(spacing: 10) {
                    Text(verbatim: Version.withBase)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                    MacSupporterMark()
                }
                .padding(.top, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .onChange(of: feed.facts(model), initial: true) { _, new in feed.apply(new, model) }
        // ‹ › and, once scrolled, the page name.
        .overlay(alignment: .top) {
            StateBar(title: "Allgemein", state: headerState, back: back)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        // macOS 26 places a milky bar over every scroll area by itself; switched off here.
        .pagesScroll()
    }

    // **`playback` and `presentation` do not belong here.** They go in the profile,
    // next to Quick Connect, as on iPhone, iPad and TV. Promising *all* settings in one
    // place via Command-comma shrank the profile to one row and buried appearance two
    // levels deep. What stays here concerns the device: offline, integration, server.

    /// **A group of its own, before integration.**
    ///
    /// Not under *Appearance*: downloads are not a matter of taste but a feature that
    /// takes up space. Not under *Integration*: that is for third-party services.
    /// Off by default, so exactly one row appears here.
    private var offline: some View {
        SettingGroup(title: "Offline") {
            switchRow("downloadsAn", "arrow.down.circle")
            if feed.isOn("downloadsAn") {
                GroupLine()
                switchRow("nurUeberWLAN", "wifi")
                GroupLine()
                switchRow("naechsteFolgeLaden", "play.square.stack")
                GroupLine()
                if let row = feed.row("downloadsSpeicher") {
                    ValuesRow(symbol: "internaldrive", title: feed.title("downloadsSpeicher"),
                              under: feed.under("downloadsSpeicher"), value: feed.shown("downloadsSpeicher"))
                        .disabled(!row.enabled)
                }
            }
        }
        // **Switching off never deletes anything unasked.** On the Mac the confirmation is
        // a system dialog instead of a sheet: the question belongs to the window, not to a
        // row in it.
        .confirmationDialog(Text("Downloads ausschalten?"),
                            isPresented: Binding(get: { feed.asksAboutDownloads },
                                                 set: { if !$0 { feed.dismissQuestion() } })) {
            Button("Behalten") { feed.answerDisable(delete: false) }
            Button("Alles entfernen", role: .destructive) { feed.answerDisable(delete: true) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(verbatim: disableText)
        }
    }

    /// Rows, second lines, dimming and the "turn Downloads off" question come from the Rust core;
    /// symbols, groups and the Mac wording (`SettingsWording`) stay here.
    private let feed = SettingsRowsFeed.shared

    @ViewBuilder private func switchRow(_ key: String, _ symbol: String) -> some View {
        if let row = feed.row(key) {
            ToggleRow(symbol: symbol, title: feed.title(key), under: feed.under(key), an: feed.binding(key))
                .disabled(!row.enabled)
        }
    }

    private var disableText: String {
        let b = DownloadRules.allocation(model.downloads.entries)
        return String(localized: "\(b.count) Titel bleiben auf diesem Mac")
            + " · " + DownloadRules.size(b.bytes)
    }

    /// **Seerr and Discord inside "Server und Dienste"**, as the iPhone keeps Seerr there.
    /// Rows the connected kind cannot use are not shown (`ServerCapability`).
    @ViewBuilder private var serviceRows: some View {
        if model.can(.seerr) {
            GroupLine()
            ValuesRow(symbol: "sparkle.magnifyingglass", title: feed.title("seerr"),
                       under: feed.under("seerr"),
                       value: model.seerr.connected ? String(localized: "Verbunden") : nil,
                       action: { navigator.openIt(.seerr, in: section) })
        }
        // **In the sandbox it is not shown at all.** Discord's socket lives in a `TMPDIR`
        // the sandbox replaces, the WebSocket rejects a missing Origin, and the HTTP
        // transport refuses the command (4002); all three were tested on a device. A
        // greyed-out switch would raise the question every time.
        if !inSandbox {
            GroupLine()
            ToggleRow(symbol: "bubble.left.and.text.bubble.right",
                          title: Text(verbatim: "Discord"),
                          under: Text("Zeigt im Profil, was gerade läuft"),
                          an: Binding(get: { model.discordShow },
                                      set: { model.discordShow = $0 }))
        }
    }

    /// Is the app running in the sandbox? In the Store it is mandatory.
    ///
    /// Read from the home directory rather than an environment variable: a sandboxed
    /// app gets its container as home, and that is also why it cannot see Discord's
    /// socket. The check measures the same thing that is the obstacle.
    private var inSandbox: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    @State private var headersOpen = false

    private var server: some View {
        SettingGroup(title: "Server und Dienste") {
            ValuesRow(symbol: "externaldrive.connected.to.line.below",
                       title: Text(verbatim: model.serverName ?? String(localized: "Server")),
                       value: model.serverVersion ?? "?")
            GroupLine()
            ValuesRow(symbol: "wifi", title: Text("Verbindung prüfen"),
                       under: verification.map { Text(verbatim: $0) },
                       value: examine ? String(localized: "Moment…") : nil,
                       trailingSymbol: examine ? nil : "arrow.triangle.2.circlepath",
                       action: examine ? nil : { check() })
            GroupLine()
            // Custom headers for a service in front of the server (issue #4): the editor opens
            // in place under the row.
            Button { withAnimation(Theme.timeFloat) { headersOpen.toggle() } } label: {
                ValuesRow(symbol: "key", title: feed.title("eigeneHeader"),
                           under: feed.under("eigeneHeader"),
                           arrow: true, hoverable: true)
            }
            .buttonStyle(Theme.PressRow())
            if headersOpen {
                MacOwnHeaders(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            serviceRows
        }
    }

    // **Rate, Discord and Report a problem are now in the profile**, at the very
    // bottom under Server/Sign out; here they were rarely noticed.

    @Environment(\.openURL) private var open

    private func check() {
        examine = true
        Task {
            verification = await model.connectionCheck(deadline: .seconds(12))
            examine = false
        }
    }
}
