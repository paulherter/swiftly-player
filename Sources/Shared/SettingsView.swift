import JellyfinKit
import SwiftUI
import SwiftlyCore

/// App settings.
///
/// Same structure as the profile page: flat rows with hairlines, groups
/// separated only by whitespace and a small spaced-out title.
///
/// This covers what concerns the app. Everything about playback (quality,
/// language, behavior) lives on its own page; otherwise the same thing would
/// appear in two places.
struct SettingsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var verification: String?
    @State private var examine = false

    var body: some View {
        ZStack(alignment: .top) {
            // The same background as every other page. It was briefly its own
            // (`gruppengrund`), because pure black under a card was the whole jump at once;
            // since the background is #101010 the jump is a fifth of that and needs no
            // exception.
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                // **The title sits next to the arrow, not below it.**
                //
                // It used to be its own line under a floating arrow: two lines for one piece
                // of information, and the arrow belonged to nothing. `SubpageHeader` puts
                // both in one line, the same one that the watchlist and downloaded series
                // already use.
                ScrollView { content.padding(.top, -Theme.firstGroupTrim) }
                    .scrollIndicators(.hidden)
            }
            .fadingUnderSubpageHeader(title: String(localized: "Allgemein")) { back() }
        }
        .overlay(alignment: .topTrailing) {
            // **turning it off deletes nothing unasked.** Silently deleting forty
            // gigabytes someone downloaded over a week would be the worst variant. Kept
            // files reappear as soon as the switch is flipped again.
            ActionSheet(opened: Binding(get: { feed.asksAboutDownloads },
                                        set: { if !$0 { feed.dismissQuestion() } }),
                        title: disableTitle, actions: [
                TitleAction(symbol: "tray.and.arrow.down", text: "Behalten") {
                    feed.answerDisable(delete: false)
                },
                TitleAction(symbol: "trash", text: "Alles entfernen", cautionary: true) {
                    feed.answerDisable(delete: true)
                },
            ])
        }
        .onChange(of: feed.facts(model), initial: true) { _, new in feed.apply(new, model) }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
    }

    /// The rows, their texts, dimming and the question come from the Rust core; the symbols and the
    /// layout stay here.
    private let feed = SettingsRowsFeed.shared

    private var disableTitle: String {
        let b = DownloadRules.allocation(model.downloads.entries)
        return String(localized: "\(b.count) Titel bleiben auf dem Gerät")
            + " · " + DownloadRules.size(b.bytes)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Side by side. Both groups are short; stacked in one column they would leave
            // two thirds of the page empty.
            //
            // Explicitly **not** merged with playback and profile into one page, as the TV
            // does. There the reason is the remote: every saved hop is a saved trip. A tap
            // on the iPad costs nothing.
            if wide {
                // **Zero, since the groups are cards.** Each card already carries
                // `Theme.rand` left and right; with 56 in between, 112 points stood between two
                // cards, which is too narrow for them. The cards carry the spacing themselves
                // now.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) { offline }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) { server; sync }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                offline
                server
                sync
            }
            // **Support, always reachable.** Below the device settings, before the
            // version line: it concerns the app, not this device or the server.
            SupportSettingsGroup()

            // **Not typed.** This used to say "Swiftly 1.0", a number that became wrong
            // long ago and that nobody updates. The Mac already read it from the bundle;
            // this was the last copy. Use the component, not a third copy: degree, color
            // and scaling live in `Footer`.
            HStack(spacing: 8) {
                Footer(Text(verbatim: Version.withBase))
                SupporterMark()
            }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 28)
        }
        .padding(.bottom, 40)
    }

    // MARK: Gruppen

    // **Appearance is no longer here**, but its own page in the profile next to
    // "Playback", together with the home page, without a submenu inside a submenu.

    /// **A group of its own, placed before integration.**
    ///
    /// Not under *Appearance*: downloads are not a matter of taste but a function
    /// that occupies space on the device. Not under *Integration*: that is for
    /// third-party services. And before *Server*, because it concerns this device,
    /// not that one.
    ///
    /// **** off by default, and then exactly one row appears here.
    private var offline: some View {
        SettingGroup(title: "Offline") {
            if let rows = feed.section("Offline")?.rows {
                ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                    if index > 0 { SheetLine() }
                    coreRow(row)
                }
            }
        }
    }

    /// A switch or info row of the core, in the look of the old rows. **The number is in the row,
    /// not behind it** (storage): anyone who wants to know how much is used should not have to tap.
    @ViewBuilder private func coreRow(_ row: SwiftlyCore.SettingsRow) -> some View {
        switch row.control {
        case .switch:
            ChoiceRow(symbol: SettingsRowsFeed.symbol(row.key), title: row.titleText,
                      under: row.underText, an: feed.binding(row.key))
                .disabled(!row.enabled)
        default:
            ValueRow(symbol: SettingsRowsFeed.symbol(row.key), title: row.titleText,
                     under: row.underText, value: feed.shown(row.key), dimmedDown: !row.enabled)
        }
    }

    private var server: some View {
        let trigger: (() -> Void)? = examine ? nil : { check() }

        return SettingGroup(title: "Server und Dienste") {
            ValueRow(symbol: "externaldrive.connected.to.line.below",
                      title: Text(verbatim: model.serverName ?? "Server"),
                      value: model.serverVersion ?? "?")
            SheetLine()
            ValueRow(symbol: "wifi", title: Text("Verbindung prüfen"),
                      under: verification.map { Text(verbatim: $0) },
                      value: examine ? String(localized: "Moment…") : nil,
                      action: trigger, inPlace: true)
            SheetLine()
            // **Custom headers, issue #4.** Only for servers behind a service like
            // Cloudflare Access; everyone else never enters.
            NavigationLink {
                OwnHeadersPage(model: model)
            } label: {
                linkRow("eigeneHeader")
            }
            .buttonStyle(Theme.PressRow())
            // Seerr signs in with the media server's user name and password; not every kind
            // has that (`ServerCapability.seerr`).
            if feed.row("seerr") != nil {
                SheetLine()
                NavigationLink(value: SeerrRoute()) {
                    linkRow("seerr")
                }
                .buttonStyle(Theme.PressRow())
            }
        }
    }

    @ViewBuilder private func linkRow(_ key: String) -> some View {
        if let row = feed.row(key) {
            ValueRow(symbol: SettingsRowsFeed.symbol(key), title: row.titleText, under: row.underText,
                     value: feed.shown(key), chevron: true)
        }
    }

    /// **Settings follow the account to every device** (`SettingsSyncRun`). On by default.
    @ViewBuilder private var sync: some View {
        // Only servers that keep display preferences (`ServerCapability.settingsSync`); the core
        // leaves the section out otherwise.
        if let rows = feed.section("Synchronisierung")?.rows {
            SettingGroup(title: "Synchronisierung") {
                ForEach(rows, id: \.key) { coreRow($0) }
            }
        }
    }

    // MARK: Kleinkram

    @Environment(\.openURL) private var open



    private func check() {
        examine = true
        Task {
            verification = await model.connectionCheck(deadline: .seconds(12))
            examine = false
        }
    }
}
